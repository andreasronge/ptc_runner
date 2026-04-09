defmodule PtcRunner.Meta.Author do
  @moduledoc """
  An Author in the coevolution system — a PTC-Lisp program that generates problems.

  Authors compute ground truth from data context. Their fitness is based on
  difficulty calibration: problems solved 40-60% of the time score highest.
  Authors that are too easy or too hard get selected against.
  """

  alias PtcRunner.Evolve.{Individual, Operators}
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Parser

  @type t :: %__MODULE__{
          id: String.t(),
          source: String.t(),
          ast: term(),
          parent_id: String.t() | nil,
          generation: non_neg_integer(),
          fitness: float() | nil,
          output_type: atom(),
          description: String.t(),
          metadata: map()
        }

  defstruct [
    :id,
    :source,
    :ast,
    :parent_id,
    :fitness,
    :output_type,
    generation: 0,
    description: "",
    metadata: %{}
  ]

  @doc """
  Create an Author from PTC-Lisp source code.

  The source should be an expression that computes a value from `data/*` variables.
  """
  @spec from_source(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_source(source, opts \\ []) do
    case Parser.parse(source) do
      {:ok, ast} ->
        author = %__MODULE__{
          id: opts[:id] || generate_id(),
          source: source,
          ast: ast,
          parent_id: opts[:parent_id],
          generation: opts[:generation] || 0,
          output_type: opts[:output_type] || :integer,
          description: opts[:description] || "",
          metadata: opts[:metadata] || %{}
        }

        {:ok, author}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Run an Author program to generate a problem.

  Returns a problem map compatible with `Evolve.Loop.run/3`, or `{:error, reason}`.
  """
  @spec generate_problem(t(), map()) :: {:ok, map()} | {:error, term()}
  def generate_problem(%__MODULE__{} = author, context) do
    case Lisp.run(author.source, context: context, timeout: 1000) do
      {:ok, step} ->
        problem = %{
          name: "author-#{author.id}",
          source: author.source,
          expected_output: step.return,
          output_type: author.output_type,
          context: context,
          description: author.description
        }

        {:ok, problem}

      {:error, step} ->
        {:error, {:author_failed, step.fail}}
    end
  end

  @doc """
  Compute Author fitness from solver success rate.

  `fitness = -abs(success_rate - 0.5) - lambda_size * node_count / 100`

  Problems solved ~50% of the time score highest (difficulty frontier).
  Size penalty prevents trivial Authors.
  """
  @spec compute_fitness(float(), non_neg_integer(), keyword()) :: float()
  def compute_fitness(success_rate, node_count, opts \\ []) do
    lambda_size = Keyword.get(opts, :lambda_size, 0.02)
    -abs(success_rate - 0.5) - lambda_size * node_count / 100
  end

  @doc """
  Mutate an Author's AST using GP operators.

  Uses only safe operators (point_mutation, arg_swap) to preserve program
  structure. Validates the mutant by running it — rejects mutations that
  produce nil, crash, or change the output type.
  """
  @spec mutate(t(), map()) :: {:ok, t()} | nil
  def mutate(%__MODULE__{source: source, id: parent_id} = author, context \\ %{}) do
    # Use safe operators that tweak values without destroying structure
    operator = Enum.random([:point_literal, :point_symbol, :arg_swap])

    case Individual.from_source(source, parent_ids: [parent_id]) do
      {:ok, ind} ->
        case Operators.mutate(ind, operator: operator) do
          {:ok, mutated} ->
            case from_source(mutated.source,
                   parent_id: parent_id,
                   output_type: author.output_type,
                   description: author.description,
                   metadata: mutated.metadata
                 ) do
              {:ok, new_author} ->
                validate_author(new_author, author, context)

              {:error, _} ->
                nil
            end

          {:error, _} ->
            nil
        end

      {:error, _} ->
        nil
    end
  end

  # Reject mutants that crash or change output type
  defp validate_author(new_author, _original, context) when context == %{} do
    # No context to validate against — accept optimistically
    {:ok, new_author}
  end

  defp validate_author(new_author, _original, context) do
    case generate_problem(new_author, context) do
      {:ok, problem} ->
        if valid_output?(problem.expected_output, new_author.output_type) do
          {:ok, new_author}
        else
          nil
        end

      {:error, _} ->
        nil
    end
  end

  defp valid_output?(nil, _type), do: false
  defp valid_output?(output, :integer), do: is_integer(output)
  defp valid_output?(output, :number), do: is_number(output)
  defp valid_output?(output, :string), do: is_binary(output)
  defp valid_output?(output, :list), do: is_list(output)
  defp valid_output?(output, :map), do: is_map(output)
  defp valid_output?(_output, _type), do: true

  defp generate_id do
    "author-#{:erlang.unique_integer([:positive, :monotonic])}"
  end
end
