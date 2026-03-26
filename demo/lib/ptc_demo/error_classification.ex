defmodule PtcDemo.ErrorClassification do
  @moduledoc """
  Classifies benchmark failures into a normalized taxonomy.

  Handles two input types:
  - Structured atom reasons from `step.fail.reason` (execution-phase errors)
  - Flat error strings from demo validation (validation-phase errors)

  The classifier prefers structured inputs. When `result.step.fail` is present,
  the atom reason is used directly. String parsing is only a fallback for
  benchmark-layer validation messages.

  ## Categories

  Ten primary categories with optional subtypes:

  - `:parse_error` — PTC-Lisp parsing failed
  - `:no_code_found` — no code block in LLM response
  - `:multiple_code_blocks` — multiple code blocks found
  - `:static_analysis_error` — rejected before eval (e.g., invalid arity)
  - `:runtime_error` — eval/type/arity errors during execution
  - `:tool_error` — tool execution failures
  - `:validation_error` — result doesn't match expected type/constraint
  - `:timeout` — execution time limit exceeded
  - `:budget_exhausted` — turn budget exhausted
  - `:resource_error` — memory exceeded
  - `:unknown_error` — unclassifiable fallback
  """

  @typedoc "A classified failure."
  @type classification :: %{
          category: atom(),
          subtype: atom() | nil,
          phase: :execution | :validation,
          raw_reason: String.t(),
          normalized_reason: String.t()
        }

  # Mapping from core step.fail.reason atoms to {category, subtype}
  @atom_mapping %{
    # Response handling
    parse_error: {:parse_error, nil},
    no_code_found: {:no_code_found, nil},
    multiple_code_blocks: {:multiple_code_blocks, nil},
    # Static analysis
    analysis_error: {:static_analysis_error, nil},
    invalid_arity: {:static_analysis_error, :invalid_arity},
    # Runtime
    eval_error: {:runtime_error, :eval_error},
    type_error: {:runtime_error, :type_error},
    arity_error: {:runtime_error, :arity_error},
    unbound_var: {:runtime_error, :unbound_var},
    not_callable: {:runtime_error, :not_callable},
    runtime_error: {:runtime_error, nil},
    failed: {:runtime_error, :explicit_fail},
    # Tools
    tool_error: {:tool_error, nil},
    unknown_tool: {:tool_error, :unknown_tool},
    tool_not_found: {:tool_error, :tool_not_found},
    reserved_tool_name: {:tool_error, :reserved_tool_name},
    tool_call_limit_exceeded: {:tool_error, :tool_call_limit_exceeded},
    # Validation (return signature validation in core)
    validation_error: {:validation_error, nil},
    return_validation_failed: {:validation_error, :return_validation_failed},
    # Resources
    timeout: {:timeout, nil},
    mission_timeout: {:timeout, :mission_timeout},
    memory_exceeded: {:resource_error, :memory_exceeded},
    # Budget
    max_turns_exceeded: {:budget_exhausted, nil},
    turn_budget_exhausted: {:budget_exhausted, nil},
    budget_exhausted: {:budget_exhausted, nil},
    max_depth_exceeded: {:budget_exhausted, :max_depth_exceeded},
    # LLM
    llm_error: {:unknown_error, :llm_error},
    llm_not_found: {:unknown_error, :llm_not_found},
    llm_registry_required: {:unknown_error, :llm_registry_required},
    invalid_llm: {:unknown_error, :invalid_llm},
    # Chain
    chained_failure: {:runtime_error, :chained_failure},
    # Template
    template_error: {:unknown_error, :template_error}
  }

  @doc """
  Classify a test failure result.

  Takes a result map as built by `LispTestRunner.run_test/8`. Resolution order:

  1. `step.fail.reason` — structured run-level failure (execution phase)
  2. Last failed turn's `result.reason` in `step.turns` — covers cases where
     the run ended without `step.fail` but turns carried structured errors
  3. `result.error` string — fallback for demo validation messages

  ## Examples

      iex> result = %{step: %PtcRunner.Step{fail: %{reason: :parse_error, message: "bad syntax"}}, error: "something"}
      iex> c = PtcDemo.ErrorClassification.classify(result)
      iex> c.category
      :parse_error
      iex> c.phase
      :execution

      iex> result = %{step: nil, error: "Wrong type: got 42 (:integer), expected :string"}
      iex> c = PtcDemo.ErrorClassification.classify(result)
      iex> c.category
      :validation_error
      iex> c.subtype
      :wrong_type

  """
  @spec classify(map()) :: classification()
  def classify(result) do
    with :none <- extract_from_step_fail(result),
         :none <- extract_from_last_failed_turn(result) do
      classify_string(result[:error] || "Unknown error")
    end
  end

  @doc """
  Classify each failed turn in a step's turn list.

  Returns a list of `{turn_number, classification}` tuples for turns
  where `success?` is false and `result.reason` is a structured atom.
  Turns without structured reasons are skipped.

  ## Examples

      iex> t1 = PtcRunner.Turn.failure(1, "raw", nil, %{reason: :parse_error, message: "bad"})
      iex> t2 = PtcRunner.Turn.success(2, "raw", "(+ 1 2)", 3)
      iex> t3 = PtcRunner.Turn.failure(3, "raw", "(/ 1 0)", %{reason: :eval_error, message: "div/0"})
      iex> step = %PtcRunner.Step{turns: [t1, t2, t3]}
      iex> PtcDemo.ErrorClassification.classify_turns(step) |> Enum.map(fn {n, c} -> {n, c.category} end)
      [{1, :parse_error}, {3, :runtime_error}]

  """
  @spec classify_turns(PtcRunner.Step.t()) :: [{pos_integer(), classification()}]
  def classify_turns(%{turns: nil}), do: []
  def classify_turns(%{turns: []}), do: []

  def classify_turns(%{turns: turns}) do
    turns
    |> Enum.reject(& &1.success?)
    |> Enum.flat_map(fn turn ->
      case turn.result do
        %{reason: reason, message: message} when is_atom(reason) ->
          [{turn.number, classify_atom(reason, message)}]

        %{reason: reason} when is_atom(reason) ->
          [{turn.number, classify_atom(reason, to_string(reason))}]

        _ ->
          []
      end
    end)
  end

  # Priority 1: structured atom from step.fail
  defp extract_from_step_fail(%{step: %{fail: %{reason: reason, message: message}}})
       when is_atom(reason) do
    classify_atom(reason, message)
  end

  defp extract_from_step_fail(%{step: %{fail: %{reason: reason}}}) when is_atom(reason) do
    classify_atom(reason, to_string(reason))
  end

  defp extract_from_step_fail(_), do: :none

  # Priority 2: last failed turn's structured reason
  defp extract_from_last_failed_turn(%{step: %{turns: turns}})
       when is_list(turns) and turns != [] do
    turns
    |> Enum.reverse()
    |> Enum.find(fn turn -> not turn.success? end)
    |> case do
      %{result: %{reason: reason, message: message}} when is_atom(reason) ->
        classify_atom(reason, message)

      %{result: %{reason: reason}} when is_atom(reason) ->
        classify_atom(reason, to_string(reason))

      _ ->
        :none
    end
  end

  defp extract_from_last_failed_turn(_), do: :none

  defp classify_atom(reason, message) do
    {category, subtype} = Map.get(@atom_mapping, reason, {:unknown_error, nil})

    build(category, subtype, :execution, message)
  end

  defp classify_string("No result returned") do
    build(:no_code_found, :no_result, :validation, "No result returned")
  end

  defp classify_string("Wrong type:" <> _ = msg) do
    build(:validation_error, :wrong_type, :validation, msg)
  end

  defp classify_string("Expected keys " <> _ = msg) do
    build(:validation_error, :missing_keys, :validation, msg)
  end

  defp classify_string("Query failed:" <> _ = msg) do
    build(:unknown_error, :query_failed, :validation, msg)
  end

  # Constraint failures — all start with "Expected"
  defp classify_string("Expected " <> _ = msg) do
    build(:validation_error, :constraint_failed, :validation, msg)
  end

  defp classify_string(msg) do
    build(:unknown_error, nil, :validation, msg)
  end

  defp build(category, subtype, phase, raw_reason) do
    %{
      category: category,
      subtype: subtype,
      phase: phase,
      raw_reason: raw_reason,
      normalized_reason: to_string(category)
    }
  end
end
