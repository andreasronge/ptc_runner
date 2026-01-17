defmodule PtcRunner.Step do
  @moduledoc """
  Result of executing a PTC program or SubAgent mission.

  Returned by both `PtcRunner.Lisp.run/2` and `PtcRunner.SubAgent.run/2`.

  ## Fields

  ### `return`

  The computed result value on success.

  - **Type:** `term() | nil`
  - **Set when:** Mission/program completed successfully
  - **Nil when:** Execution failed (check `fail` field)

  ### `fail`

  Error information on failure. See `t:fail/0` for the structure.

  - **Type:** `t:fail/0 | nil`
  - **Set when:** Execution failed
  - **Nil when:** Execution succeeded

  ### `memory`

  Final memory state after execution.

  - **Type:** `map()`
  - **Always set:** Contains accumulated memory from all operations
  - **Access in PTC-Lisp:** values available as plain symbols

  ### `signature`

  The contract used for validation.

  - **Type:** `String.t() | nil`
  - **Set when:** Signature was provided to `run/2`
  - **Used for:** Type propagation when chaining steps

  ### `usage`

  Execution metrics. See `t:usage/0` for available fields.

  - **Type:** `t:usage/0 | nil`
  - **Set when:** Execution completed (success or failure after running)
  - **Nil when:** Early validation failure (before execution)

  ### `turns`

  List of Turn structs capturing each LLM interaction cycle. See `PtcRunner.Turn`.

  - **Type:** `[PtcRunner.Turn.t()] | nil`
  - **Set when:** SubAgent execution
  - **Nil when:** Lisp execution

  ### `trace_id`

  Unique identifier for this execution (for tracing correlation).

  - **Type:** `String.t() | nil`
  - **Set when:** SubAgent execution (32-character hex string)
  - **Nil when:** Lisp execution
  - **Used for:** Correlating traces in parallel and nested agent executions

  ### `parent_trace_id`

  ID of parent trace for nested agent calls.

  - **Type:** `String.t() | nil`
  - **Set when:** This agent was spawned by another agent
  - **Nil when:** Root-level execution (no parent)
  - **Used for:** Linking child executions to their parent

  See `PtcRunner.Tracer` for trace generation and management.

  ### `field_descriptions`

  Descriptions for signature fields, propagated from SubAgent.

  - **Type:** `map() | nil`
  - **Set when:** SubAgent had `field_descriptions` option
  - **Nil when:** No field descriptions provided
  - **Used for:** Passing field documentation through chained executions

  ### `messages`

  Full conversation history in OpenAI format.

  - **Type:** `[t:message/0] | nil`
  - **Set when:** `collect_messages: true` option passed to `SubAgent.run/2`
  - **Nil when:** `collect_messages: false` (default)
  - **Used for:** Debugging, persistence, and displaying the LLM conversation

  ## Error Reasons

  Complete list of error reasons in `step.fail.reason`:

  | Reason | Source | Description |
  |--------|--------|-------------|
  | `:parse_error` | Lisp | Invalid PTC-Lisp syntax |
  | `:analysis_error` | Lisp | Semantic error (undefined variable, etc.) |
  | `:eval_error` | Lisp | Runtime error (division by zero, etc.) |
  | `:timeout` | Both | Execution exceeded time limit |
  | `:memory_exceeded` | Both | Process exceeded heap limit |
  | `:validation_error` | Both | Input or output doesn't match signature |
  | `:tool_error` | SubAgent | Tool raised an exception |
  | `:tool_not_found` | SubAgent | Called non-existent tool |
  | `:reserved_tool_name` | SubAgent | Attempted to register `return` or `fail` |
  | `:max_turns_exceeded` | SubAgent | Turn limit reached without termination |
  | `:max_depth_exceeded` | SubAgent | Nested agent depth limit exceeded |
  | `:turn_budget_exhausted` | SubAgent | Total turn budget exhausted |
  | `:mission_timeout` | SubAgent | Total mission duration exceeded |
  | `:llm_error` | SubAgent | LLM callback failed after retries |
  | `:llm_required` | SubAgent | LLM option is required for agent execution |
  | `:no_code_found` | SubAgent | No PTC-Lisp code found in LLM response |
  | `:llm_not_found` | SubAgent | LLM atom not in registry |
  | `:llm_registry_required` | SubAgent | Atom LLM used without registry |
  | `:invalid_llm` | SubAgent | Registry value not a function |
  | `:chained_failure` | SubAgent | Chained onto a failed step |
  | `:template_error` | SubAgent | Template placeholder missing |
  | Custom atoms | SubAgent | From `(fail {:reason :custom ...})` |

  ## Usage Patterns

  ### Success Check

      case SubAgent.run(prompt, opts) do
        {:ok, step} ->
          IO.puts("Result: \#{inspect(step.return)}")
          IO.puts("Took \#{step.usage.duration_ms}ms")

        {:error, step} ->
          IO.puts("Failed: \#{step.fail.reason} - \#{step.fail.message}")
      end

  ### Chaining Steps

  Pass a successful step's return and signature to the next step:

      {:ok, step1} = SubAgent.run("Find emails",
        signature: "() -> {count :int, _ids [:int]}",
        llm: llm
      )

      # Option 1: Explicit
      {:ok, step2} = SubAgent.run("Process emails",
        context: step1.return,
        context_signature: step1.signature,
        llm: llm
      )

      # Option 2: Auto-extraction (SubAgent only)
      {:ok, step2} = SubAgent.run("Process emails",
        context: step1,  # Extracts return and signature automatically
        llm: llm
      )

  ### Accessing Firewalled Data

  Fields prefixed with `_` are hidden from LLM history but available in `return`:

      {:ok, step} = SubAgent.run("Find emails",
        signature: "() -> {count :int, _email_ids [:int]}",
        llm: llm
      )

      step.return.count      #=> 5 (visible to LLM)
      step.return._email_ids #=> [101, 102, 103, 104, 105] (hidden from LLM)
  """

  defstruct [
    :return,
    :fail,
    :memory,
    :signature,
    :usage,
    :turns,
    :trace_id,
    :parent_trace_id,
    :field_descriptions,
    :prints,
    :tool_calls,
    :messages,
    :prompt,
    :original_prompt,
    :tools
  ]

  @typedoc """
  Error information on failure.

  Fields:
  - `reason`: Machine-readable error code (atom)
  - `message`: Human-readable description
  - `op`: Optional operation/tool that failed
  - `details`: Optional additional context
  """
  @type fail :: %{
          required(:reason) => atom(),
          required(:message) => String.t(),
          optional(:op) => String.t(),
          optional(:details) => map()
        }

  @typedoc """
  Execution metrics.

  Fields:
  - `duration_ms`: Total execution time
  - `memory_bytes`: Peak memory usage
  - `turns`: Number of LLM turns used (SubAgent only, optional)
  - `input_tokens`: Total input tokens (SubAgent only, optional)
  - `output_tokens`: Total output tokens (SubAgent only, optional)
  - `total_tokens`: Input + output tokens (SubAgent only, optional)
  - `llm_requests`: Number of LLM API calls (SubAgent only, optional)
  - `schema_used`: Whether JSON schema was sent to LLM (JSON mode only, optional)
  - `schema_bytes`: Size of JSON schema in bytes (JSON mode only, optional)
  """
  @type usage :: %{
          required(:duration_ms) => non_neg_integer(),
          required(:memory_bytes) => non_neg_integer(),
          optional(:turns) => pos_integer(),
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:total_tokens) => non_neg_integer(),
          optional(:llm_requests) => non_neg_integer(),
          optional(:schema_used) => boolean(),
          optional(:schema_bytes) => non_neg_integer()
        }

  @typedoc """
  Tool call information in trace.

  Fields:
  - `name`: Tool name
  - `args`: Arguments passed to tool
  - `result`: Tool result
  - `error`: Error message if tool failed
  - `timestamp`: When tool was called
  - `duration_ms`: How long tool took
  """
  @type tool_call :: %{
          name: String.t(),
          args: map(),
          result: term(),
          error: String.t() | nil,
          timestamp: DateTime.t(),
          duration_ms: non_neg_integer()
        }

  @typedoc """
  A single message in OpenAI format.

  Fields:
  - `role`: The message role (:system, :user, or :assistant)
  - `content`: The message content
  """
  @type message :: %{
          role: :system | :user | :assistant,
          content: String.t()
        }

  @typedoc """
  Step result struct.

  One of `return` or `fail` will be set, but never both:
  - Success: `return` is set, `fail` is nil
  - Failure: `fail` is set, `return` is nil

  The `trace_id` and `parent_trace_id` fields are used for tracing correlation
  in parallel and nested agent executions. See `PtcRunner.Tracer` for details.
  """
  @type t :: %__MODULE__{
          return: term() | nil,
          fail: fail() | nil,
          memory: map(),
          signature: String.t() | nil,
          usage: usage() | nil,
          turns: [PtcRunner.Turn.t()] | nil,
          trace_id: String.t() | nil,
          parent_trace_id: String.t() | nil,
          field_descriptions: map() | nil,
          prints: [String.t()],
          tool_calls: [tool_call()],
          messages: [message()] | nil,
          prompt: String.t() | nil,
          tools: map() | nil
        }

  @doc """
  Creates a new successful Step.

  ## Examples

      iex> step = PtcRunner.Step.ok(%{count: 5}, %{})
      iex> step.return
      %{count: 5}
      iex> step.fail
      nil

  """
  @spec ok(term(), map()) :: t()
  def ok(return, memory) do
    %__MODULE__{
      return: return,
      fail: nil,
      memory: memory,
      signature: nil,
      usage: nil,
      turns: nil,
      trace_id: nil,
      parent_trace_id: nil,
      field_descriptions: nil,
      prints: [],
      tool_calls: []
    }
  end

  @doc """
  Creates a new failed Step.

  ## Examples

      iex> step = PtcRunner.Step.error(:timeout, "Execution exceeded time limit", %{})
      iex> step.fail.reason
      :timeout
      iex> step.return
      nil

  """
  @spec error(atom(), String.t(), map()) :: t()
  def error(reason, message, memory) do
    error(reason, message, memory, %{})
  end

  @doc """
  Creates a failed Step with additional details.

  ## Examples

      iex> PtcRunner.Step.error(:validation_failed, "Invalid input", %{}, %{field: "name"})
      %PtcRunner.Step{
        return: nil,
        fail: %{reason: :validation_failed, message: "Invalid input", details: %{field: "name"}},
        memory: %{},
        signature: nil,
        usage: nil,
        turns: nil,
        trace_id: nil,
        parent_trace_id: nil,
        field_descriptions: nil
      }

  """
  @spec error(atom(), String.t(), map(), map()) :: t()
  def error(reason, message, memory, details) do
    %__MODULE__{
      return: nil,
      fail: %{reason: reason, message: message, details: details},
      memory: memory,
      signature: nil,
      usage: nil,
      turns: nil,
      trace_id: nil,
      parent_trace_id: nil,
      field_descriptions: nil,
      prints: [],
      tool_calls: []
    }
  end
end
