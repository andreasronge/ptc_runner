defmodule PtcRunner.Step do
  @moduledoc """
  Result of executing a PTC program or SubAgent mission.

  Returned by both `PtcRunner.Lisp.run/2` and `PtcRunner.SubAgent.run/2`.

  ## Fields

  - `return`: The computed result value on success (nil on failure)
  - `fail`: Error information on failure (nil on success)
  - `memory`: Final memory state after execution
  - `memory_delta`: Keys that changed during execution (Lisp only, nil for SubAgent)
  - `signature`: The contract used for validation
  - `usage`: Execution metrics
  - `trace`: Execution trace for debugging (SubAgent only, nil for Lisp)
  - `trace_id`: Unique ID for this execution (for tracing correlation)
  - `parent_trace_id`: ID of parent trace (for nested agents)

  See the [Step Specification](ptc_agents/step.md) for detailed field documentation.
  """

  defstruct [
    :return,
    :fail,
    :memory,
    :memory_delta,
    :signature,
    :usage,
    :trace,
    :trace_id,
    :parent_trace_id
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
  """
  @type usage :: %{
          required(:duration_ms) => non_neg_integer(),
          required(:memory_bytes) => non_neg_integer(),
          optional(:turns) => pos_integer(),
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:total_tokens) => non_neg_integer(),
          optional(:llm_requests) => non_neg_integer()
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
  Single turn's execution history.

  Fields:
  - `turn`: Turn number
  - `program`: PTC-Lisp program executed
  - `result`: Result of executing the program
  - `tool_calls`: List of tool calls made during this turn
  """
  @type trace_entry :: %{
          turn: pos_integer(),
          program: String.t(),
          result: term(),
          tool_calls: [tool_call()]
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
          memory_delta: map() | nil,
          signature: String.t() | nil,
          usage: usage() | nil,
          trace: [trace_entry()] | nil,
          trace_id: String.t() | nil,
          parent_trace_id: String.t() | nil
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
      memory_delta: nil,
      signature: nil,
      usage: nil,
      trace: nil,
      trace_id: nil,
      parent_trace_id: nil
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
        memory_delta: nil,
        signature: nil,
        usage: nil,
        trace: nil,
        trace_id: nil,
        parent_trace_id: nil
      }

  """
  @spec error(atom(), String.t(), map(), map()) :: t()
  def error(reason, message, memory, details) do
    %__MODULE__{
      return: nil,
      fail: %{reason: reason, message: message, details: details},
      memory: memory,
      memory_delta: nil,
      signature: nil,
      usage: nil,
      trace: nil,
      trace_id: nil,
      parent_trace_id: nil
    }
  end
end
