defmodule PtcRunner.Meta.MetaLearner do
  @moduledoc """
  A meta-learner M variant — a PTC-Lisp program that selects GP operators.

  M is a PTC-Lisp function that takes a failure vector map and returns an operator
  keyword atom. M variants compete to produce the best solver improvement.

  M's AST is itself subject to GP mutation (same operators it selects among),
  creating genuine Godelian self-reference.
  """

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Parser
  alias PtcRunner.Meta.FailureVector

  @type t :: %__MODULE__{
          id: String.t(),
          source: String.t(),
          ast: term(),
          parent_id: String.t() | nil,
          generation: non_neg_integer(),
          fitness: float() | nil,
          metadata: map()
        }

  defstruct [
    :id,
    :source,
    :ast,
    :parent_id,
    :fitness,
    generation: 0,
    metadata: %{}
  ]

  @doc """
  Create a MetaLearner from PTC-Lisp source code.

  The source should be a `(fn [fv] ...)` expression that takes a failure vector
  map and returns an operator keyword.

      iex> {:ok, m} = PtcRunner.Meta.MetaLearner.from_source("(fn [fv] :point_mutation)")
      iex> m.source
      "(fn [fv] :point_mutation)"
  """
  @spec from_source(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_source(source, opts \\ []) do
    case Parser.parse(source) do
      {:ok, ast} ->
        m = %__MODULE__{
          id: opts[:id] || generate_id(),
          source: source,
          ast: ast,
          parent_id: opts[:parent_id],
          generation: opts[:generation] || 0,
          metadata: opts[:metadata] || %{}
        }

        {:ok, m}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Evaluate M with a failure vector to get an operator selection.

  Runs M's source in the PTC-Lisp sandbox with the failure vector inlined.
  Returns the operator atom or falls back to `:point_mutation` on error.
  """
  @spec select_operator(t(), FailureVector.t()) :: atom()
  def select_operator(%__MODULE__{source: source}, failure_vector) do
    fv_lisp = FailureVector.to_lisp_map(failure_vector)
    program = "(let [m #{source} fv #{fv_lisp}] (m fv))"

    case Lisp.run(program, timeout: 500) do
      {:ok, step} when is_atom(step.return) ->
        if FailureVector.valid_operator?(step.return) do
          step.return
        else
          :point_mutation
        end

      _ ->
        :point_mutation
    end
  end

  defp generate_id do
    "meta-#{:erlang.unique_integer([:positive, :monotonic])}"
  end
end
