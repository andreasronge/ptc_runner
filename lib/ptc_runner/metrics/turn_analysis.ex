defmodule PtcRunner.Metrics.TurnAnalysis do
  @moduledoc """
  Extracts per-turn interaction quality metrics from SubAgent execution results.

  All functions are pure — they take a `%Step{}` and return computed values.
  """

  alias PtcRunner.Step

  @budget_reasons [:max_turns_exceeded, :turn_budget_exhausted, :budget_exhausted]

  @doc """
  Whether turn 1 produced parseable code.

  Measures interaction quality (did the model write structurally valid code?),
  not task success. A turn that parses but fails at runtime is still "valid".

  ## Examples

      iex> turn = PtcRunner.Turn.success(1, "raw", "(+ 1 2)", 3)
      iex> step = %PtcRunner.Step{turns: [turn]}
      iex> PtcRunner.Metrics.TurnAnalysis.first_turn_valid?(step)
      true

  """
  @spec first_turn_valid?(Step.t()) :: boolean()
  def first_turn_valid?(%Step{turns: nil}), do: false
  def first_turn_valid?(%Step{turns: []}), do: false
  def first_turn_valid?(%Step{turns: [first | _]}), do: first.program != nil

  @doc """
  Fraction of turns with a `:parse_error` result reason.

  ## Examples

      iex> t1 = PtcRunner.Turn.success(1, "raw", "(+ 1 2)", 3)
      iex> step = %PtcRunner.Step{turns: [t1]}
      iex> PtcRunner.Metrics.TurnAnalysis.parse_failure_rate(step)
      0.0

  """
  @spec parse_failure_rate(Step.t()) :: float()
  def parse_failure_rate(step), do: error_rate(step, :parse_error)

  @doc """
  Fraction of turns with a `:no_code_found` result reason.
  """
  @spec no_code_rate(Step.t()) :: float()
  def no_code_rate(step), do: error_rate(step, :no_code_found)

  @doc """
  Fraction of turns with a `:multiple_code_blocks` result reason.
  """
  @spec multi_code_block_rate(Step.t()) :: float()
  def multi_code_block_rate(step), do: error_rate(step, :multiple_code_blocks)

  @doc """
  Turn number of the first successful tool call, or nil if none.

  ## Examples

      iex> t1 = PtcRunner.Turn.success(1, "raw", "(+ 1 2)", 3)
      iex> step = %PtcRunner.Step{turns: [t1]}
      iex> PtcRunner.Metrics.TurnAnalysis.turns_to_first_tool_call(step)
      nil

  """
  @spec turns_to_first_tool_call(Step.t()) :: pos_integer() | nil
  def turns_to_first_tool_call(%Step{turns: nil}), do: nil
  def turns_to_first_tool_call(%Step{turns: []}), do: nil

  def turns_to_first_tool_call(%Step{turns: turns}) do
    turns
    |> Enum.find(&((&1.tool_calls || []) != []))
    |> case do
      nil -> nil
      turn -> turn.number
    end
  end

  @doc """
  Whether the run exhausted its turn budget.

  Checks for reasons: `:max_turns_exceeded`, `:turn_budget_exhausted`, `:budget_exhausted`.

  ## Examples

      iex> step = %PtcRunner.Step{fail: %{reason: :max_turns_exceeded, message: "exceeded"}}
      iex> PtcRunner.Metrics.TurnAnalysis.budget_exhausted?(step)
      true

      iex> step = %PtcRunner.Step{return: 42}
      iex> PtcRunner.Metrics.TurnAnalysis.budget_exhausted?(step)
      false

  """
  @spec budget_exhausted?(Step.t()) :: boolean()
  def budget_exhausted?(%Step{fail: %{reason: reason}}) when reason in @budget_reasons, do: true
  def budget_exhausted?(%Step{}), do: false

  @doc """
  Number of turns used.

  ## Examples

      iex> step = %PtcRunner.Step{turns: nil}
      iex> PtcRunner.Metrics.TurnAnalysis.turn_count(step)
      0

  """
  @spec turn_count(Step.t()) :: non_neg_integer()
  def turn_count(%Step{turns: nil}), do: 0
  def turn_count(%Step{turns: turns}), do: length(turns)

  @doc """
  Computes all metrics in one call.

  The `passed?` field is provided externally via `opts[:passed?]` (from test validation),
  not derived from the Step.

  Returns a map with keys: `:first_turn_valid?`, `:parse_failure_rate`, `:no_code_rate`,
  `:multi_code_block_rate`, `:turns_to_first_tool_call`, `:budget_exhausted?`,
  `:has_failed_turn?`, `:turn_count`, `:input_tokens`, `:output_tokens`,
  `:total_tokens`, `:passed?`.
  """
  @spec analyze(Step.t(), keyword()) :: map()
  def analyze(%Step{} = step, opts \\ []) do
    {input_tokens, output_tokens, total_tokens} = extract_tokens(step)

    %{
      first_turn_valid?: first_turn_valid?(step),
      parse_failure_rate: parse_failure_rate(step),
      no_code_rate: no_code_rate(step),
      multi_code_block_rate: multi_code_block_rate(step),
      turns_to_first_tool_call: turns_to_first_tool_call(step),
      budget_exhausted?: budget_exhausted?(step),
      has_failed_turn?: has_failed_turn?(step),
      turn_count: turn_count(step),
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: total_tokens,
      passed?: opts[:passed?]
    }
  end

  @doc """
  Aggregates metrics across multiple runs.

  Input: list of maps returned by `analyze/2`.

  Returns a summary map with rates and means. Returns an empty summary
  with zero values when given an empty list.
  """
  @spec aggregate([map()]) :: map()
  def aggregate([]) do
    %{
      first_turn_validity_rate: 0.0,
      mean_parse_failure_rate: 0.0,
      mean_no_code_rate: 0.0,
      mean_multi_code_block_rate: 0.0,
      mean_turns_on_pass: nil,
      recoverable_error_salvage_rate: 0.0,
      budget_exhausted_rate: 0.0,
      pass_rate: 0.0,
      mean_input_tokens: 0.0,
      mean_output_tokens: 0.0,
      mean_total_tokens: 0.0,
      mean_total_tokens_on_pass: nil
    }
  end

  def aggregate(metrics_list) do
    count = length(metrics_list)

    passed_runs = Enum.filter(metrics_list, & &1[:passed?])

    runs_with_errors =
      Enum.filter(metrics_list, fn m ->
        m[:has_failed_turn?]
      end)

    salvaged =
      case runs_with_errors do
        [] -> 0.0
        errors -> Enum.count(errors, & &1[:passed?]) / length(errors)
      end

    %{
      first_turn_validity_rate: Enum.count(metrics_list, & &1[:first_turn_valid?]) / count,
      mean_parse_failure_rate: mean(metrics_list, :parse_failure_rate),
      mean_no_code_rate: mean(metrics_list, :no_code_rate),
      mean_multi_code_block_rate: mean(metrics_list, :multi_code_block_rate),
      mean_turns_on_pass:
        case passed_runs do
          [] -> nil
          runs -> mean(runs, :turn_count)
        end,
      recoverable_error_salvage_rate: salvaged,
      budget_exhausted_rate: Enum.count(metrics_list, & &1[:budget_exhausted?]) / count,
      pass_rate: length(passed_runs) / count,
      mean_input_tokens: mean(metrics_list, :input_tokens),
      mean_output_tokens: mean(metrics_list, :output_tokens),
      mean_total_tokens: mean(metrics_list, :total_tokens),
      mean_total_tokens_on_pass:
        case passed_runs do
          [] -> nil
          runs -> mean(runs, :total_tokens)
        end
    }
  end

  @doc """
  Whether the run had any failed turn (parse, analysis, runtime, or tool errors).

  Used for computing salvage rate: of runs that hit any error, how many still passed?
  """
  @spec has_failed_turn?(Step.t()) :: boolean()
  def has_failed_turn?(%Step{turns: nil}), do: false
  def has_failed_turn?(%Step{turns: []}), do: false
  def has_failed_turn?(%Step{turns: turns}), do: Enum.any?(turns, &(not &1.success?))

  @doc """
  Frequency map of error reasons across failed turns with structured reasons.

  Only counts turns where `result.reason` is a structured atom.
  Turns without structured reasons are skipped (not counted as `:unknown`).
  Returns an empty map when there are no qualifying failed turns.

  ## Examples

      iex> t1 = PtcRunner.Turn.failure(1, "raw", nil, %{reason: :parse_error, message: "bad"})
      iex> t2 = PtcRunner.Turn.success(2, "raw", "(+ 1 2)", 3)
      iex> t3 = PtcRunner.Turn.failure(3, "raw", "(/ 1 0)", %{reason: :eval_error, message: "div/0"})
      iex> step = %PtcRunner.Step{turns: [t1, t2, t3]}
      iex> PtcRunner.Metrics.TurnAnalysis.error_breakdown(step)
      %{parse_error: 1, eval_error: 1}

  """
  @spec error_breakdown(Step.t()) :: %{atom() => non_neg_integer()}
  def error_breakdown(%Step{turns: nil}), do: %{}
  def error_breakdown(%Step{turns: []}), do: %{}

  def error_breakdown(%Step{turns: turns}) do
    turns
    |> Enum.reject(& &1.success?)
    |> Enum.flat_map(fn turn ->
      case turn.result do
        %{reason: reason} when is_atom(reason) -> [reason]
        _ -> []
      end
    end)
    |> Enum.frequencies()
  end

  @doc """
  The most frequent error reason across failed turns, or nil if no errors.

  ## Examples

      iex> t1 = PtcRunner.Turn.failure(1, "raw", nil, %{reason: :parse_error, message: "bad"})
      iex> t2 = PtcRunner.Turn.failure(2, "raw", nil, %{reason: :parse_error, message: "bad"})
      iex> t3 = PtcRunner.Turn.failure(3, "raw", "(/ 1 0)", %{reason: :eval_error, message: "div/0"})
      iex> step = %PtcRunner.Step{turns: [t1, t2, t3]}
      iex> PtcRunner.Metrics.TurnAnalysis.dominant_error(step)
      :parse_error

  """
  @spec dominant_error(Step.t()) :: atom() | nil
  def dominant_error(step) do
    case error_breakdown(step) do
      empty when map_size(empty) == 0 -> nil
      breakdown -> breakdown |> Enum.max_by(fn {_reason, count} -> count end) |> elem(0)
    end
  end

  @doc """
  Fraction of turns with the given error reason.

  ## Examples

      iex> t1 = PtcRunner.Turn.failure(1, "raw", nil, %{reason: :parse_error, message: "bad"})
      iex> t2 = PtcRunner.Turn.success(2, "raw", "(+ 1 2)", 3)
      iex> step = %PtcRunner.Step{turns: [t1, t2]}
      iex> PtcRunner.Metrics.TurnAnalysis.error_rate(step, :parse_error)
      0.5

  """
  @spec error_rate(Step.t(), atom()) :: float()
  def error_rate(%Step{turns: nil}, _reason), do: 0.0
  def error_rate(%Step{turns: []}, _reason), do: 0.0

  def error_rate(%Step{turns: turns}, reason) do
    count = length(turns)
    errors = Enum.count(turns, &has_error_reason?(&1, reason))
    errors / count
  end

  # -- Private helpers --

  defp extract_tokens(%Step{usage: nil}), do: {0, 0, 0}

  defp extract_tokens(%Step{usage: usage}) do
    {
      Map.get(usage, :input_tokens, 0),
      Map.get(usage, :output_tokens, 0),
      Map.get(usage, :total_tokens, 0)
    }
  end

  defp has_error_reason?(%{result: %{reason: reason}}, reason), do: true
  defp has_error_reason?(_, _), do: false

  defp mean(list, key) do
    Enum.sum(Enum.map(list, &Map.get(&1, key, 0))) / length(list)
  end
end
