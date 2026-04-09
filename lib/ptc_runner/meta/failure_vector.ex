defmodule PtcRunner.Meta.FailureVector do
  @moduledoc """
  Computes a failure vector from solver evaluation results.

  The failure vector is a 6-element map that M uses to decide which GP operator
  to apply. It summarizes what went wrong (or right) with a solver's last evaluation.

  ## Fields

  - `:compile_error` — program failed to parse (boolean)
  - `:timeout` — sandbox timeout (boolean)
  - `:wrong_type` — output type doesn't match expected (boolean)
  - `:partial_score` — partial credit 0.0-1.0 (float)
  - `:size_bloat` — AST nodes > 80% of max (boolean)
  - `:no_improvement` — fitness same as or worse than parent (boolean)
  """

  @type t :: %{
          compile_error: boolean(),
          timeout: boolean(),
          wrong_type: boolean(),
          partial_score: float(),
          size_bloat: boolean(),
          no_improvement: boolean()
        }

  @valid_operators [
    :point_mutation,
    :arg_swap,
    :wrap_form,
    :subtree_delete,
    :subtree_dup,
    :crossover
  ]

  @doc """
  Compute a failure vector from an evaluation result.

  `eval_result` is the map returned by `Evolve.Evaluator.evaluate/3`.
  `opts` may include:
  - `:parent_fitness` — the parent's fitness (for no_improvement detection)
  - `:current_fitness` — this individual's fitness
  - `:program_size` — AST node count
  - `:max_ast_nodes` — maximum allowed nodes (default 80)
  - `:output_type` — expected output type atom
  """
  @spec from_eval_result(map(), keyword()) :: t()
  def from_eval_result(eval_result, opts \\ []) do
    parent_fitness = Keyword.get(opts, :parent_fitness, nil)
    current_fitness = Keyword.get(opts, :current_fitness, nil)
    program_size = Keyword.get(opts, :program_size, 0)
    max_ast_nodes = Keyword.get(opts, :max_ast_nodes, 80)

    %{
      compile_error: compile_error?(eval_result),
      timeout: timed_out?(eval_result),
      wrong_type: wrong_type?(eval_result, opts),
      partial_score: compute_partial_score(eval_result),
      size_bloat: program_size > max_ast_nodes * 0.8,
      no_improvement: no_improvement?(parent_fitness, current_fitness)
    }
  end

  @doc """
  Convert a failure vector to a PTC-Lisp map literal string.

  Used to inline the failure vector into M's evaluation program.
  """
  @spec to_lisp_map(t()) :: String.t()
  def to_lisp_map(fv) do
    "{:compile_error #{to_lisp_bool(fv.compile_error)} " <>
      ":timeout #{to_lisp_bool(fv.timeout)} " <>
      ":wrong_type #{to_lisp_bool(fv.wrong_type)} " <>
      ":partial_score #{fv.partial_score} " <>
      ":size_bloat #{to_lisp_bool(fv.size_bloat)} " <>
      ":no_improvement #{to_lisp_bool(fv.no_improvement)}}"
  end

  @doc """
  Build a failure vector from an Individual's current state.

  Used in the operator selector when a full eval_result is not available.
  Only `partial_score`, `size_bloat`, and `no_improvement` carry real signal;
  `compile_error`, `timeout`, and `wrong_type` default to false.
  """
  @spec from_individual(PtcRunner.Evolve.Individual.t(), keyword()) :: t()
  def from_individual(%{fitness: fitness, program_size: size}, opts \\ []) do
    max_ast_nodes = Keyword.get(opts, :max_ast_nodes, 80)

    %{
      compile_error: false,
      timeout: false,
      wrong_type: false,
      partial_score: fitness || 0.0,
      size_bloat: size > max_ast_nodes * 0.8,
      no_improvement: fitness == nil or fitness <= 0.0
    }
  end

  @doc """
  List of valid operator atoms that M can return.
  """
  @spec valid_operators() :: [atom()]
  def valid_operators, do: @valid_operators

  @doc """
  Check if an atom is a valid operator.
  """
  @spec valid_operator?(atom()) :: boolean()
  def valid_operator?(op), do: op in @valid_operators

  # --- Private ---

  defp compile_error?(%{error: error}) when error != nil do
    case error do
      %{reason: :parse_error} -> true
      %{reason: :syntax_error} -> true
      _ -> false
    end
  end

  defp compile_error?(_), do: false

  defp timed_out?(%{error: error}) when error != nil do
    case error do
      %{reason: :timeout} -> true
      %{reason: :killed} -> true
      _ -> false
    end
  end

  defp timed_out?(_), do: false

  defp wrong_type?(%{output: nil}, _opts), do: false
  defp wrong_type?(%{error: err}, _opts) when err != nil, do: false

  defp wrong_type?(%{output: output}, opts) do
    case Keyword.get(opts, :output_type) do
      nil -> false
      :integer -> not is_integer(output)
      :number -> not is_number(output)
      :string -> not is_binary(output)
      :list -> not is_list(output)
      :map -> not is_map(output)
      _ -> false
    end
  end

  defp compute_partial_score(%{correct: true}), do: 1.0
  defp compute_partial_score(%{error: err}) when err != nil, do: 0.0
  defp compute_partial_score(%{output: nil}), do: 0.0
  # Coarse signal: any non-crash output gets mid-credit for M's operator selector
  defp compute_partial_score(_), do: 0.5

  defp no_improvement?(nil, _current), do: false
  defp no_improvement?(_parent, nil), do: true
  defp no_improvement?(parent, current), do: current <= parent

  defp to_lisp_bool(true), do: "true"
  defp to_lisp_bool(false), do: "false"
end
