defmodule PtcRunner.Folding.Oracle do
  @moduledoc """
  External oracle for interactive coevolution.

  Computes the correct answer for a task definition against a (possibly modified)
  data context. The oracle stays OUTSIDE both evolving populations — it is the
  fixed reference that keeps the competition honest.

  A task definition is a PTC-Lisp expression + expected output type. The oracle
  runs the expression against whatever context the tester creates and returns the
  correct answer.
  """

  alias PtcRunner.Lisp

  @type task_def :: %{
          source: String.t(),
          output_type: atom()
        }

  @doc """
  Compute the correct answer for a task against a context.

  Runs `task_def.source` in the given context using the PTC-Lisp sandbox.
  Returns `{:ok, answer}` or `{:error, reason}`.
  """
  @spec evaluate(task_def(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def evaluate(task_def, context, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1000)
    max_heap = Keyword.get(opts, :max_heap, 1_250_000)

    case Lisp.run(task_def.source,
           context: context,
           timeout: timeout,
           max_heap: max_heap,
           filter_context: false
         ) do
      {:ok, step} -> {:ok, step.return}
      {:error, step} -> {:error, step.fail}
    end
  end

  @doc """
  Score a solver's answer against the oracle's correct answer.

  Returns a float in [0.0, 1.0]:
  - 1.0 for exact match
  - Partial credit for close numeric values or matching types
  - 0.0 for errors or nil
  """
  @spec score(term(), term(), atom()) :: float()
  def score(nil, _, _), do: 0.0
  def score(_, nil, _), do: 0.0

  def score(answer, expected, _type) when answer == expected, do: 1.0

  def score(answer, expected, :integer) when is_integer(answer) and is_integer(expected) do
    if expected == 0,
      do: 0.1,
      else: max(0.0, 1.0 - abs(answer - expected) / max(abs(expected), 1))
  end

  def score(answer, expected, :number) when is_number(answer) and is_number(expected) do
    if expected == 0,
      do: 0.1,
      else: max(0.0, 1.0 - abs(answer - expected) / max(abs(expected), 1))
  end

  def score(answer, expected, :list) when is_list(answer) and is_list(expected) do
    if expected == [], do: 0.1, else: 0.2
  end

  def score(answer, expected, :map) when is_map(answer) and is_map(expected) do
    if expected == %{}, do: 0.1, else: 0.2
  end

  # Type mismatch — minimal credit for producing something
  def score(answer, _expected, _type) when not is_nil(answer), do: 0.05

  def score(_, _, _), do: 0.0
end
