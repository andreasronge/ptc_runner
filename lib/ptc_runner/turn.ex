defmodule PtcRunner.Turn do
  @moduledoc """
  Captures a single LLM interaction cycle in a SubAgent execution.

  Each turn represents one complete cycle: LLM generates program → program executes → results captured.
  Turns are immutable snapshots; once created, they are never modified.

  ## Fields

  - `number` - Turn sequence number (1-indexed)
  - `raw_response` - Full LLM output including reasoning (always captured per ARC-010)
  - `program` - Parsed PTC-Lisp program, or nil if parsing failed
  - `result` - Execution result value
  - `prints` - Captured println output
  - `tool_calls` - Tool invocations made during this turn
  - `memory` - Accumulated definitions after this turn
  - `success?` - Whether the turn succeeded
  - `messages` - Messages sent to the LLM for this turn (for debugging/verification)
  - `type` - Turn type: `:normal`, `:must_return`, or `:retry` (default: `:normal`)

  ## Constructors

  Use `success/5` or `failure/5` to create turns - don't construct the struct directly.
  The constructors ensure `success?` is set correctly.
  """

  @typedoc """
  Turn type indicating the phase of execution.

  - `:normal` - Investigation turn with tools available
  - `:must_return` - Final work turn, tools stripped
  - `:retry` - Retry turn after failed return
  """
  @type turn_type :: :normal | :must_return | :retry

  defstruct [
    :number,
    :raw_response,
    :program,
    :result,
    :prints,
    :tool_calls,
    :memory,
    :success?,
    :messages,
    type: :normal
  ]

  @typedoc """
  A single tool invocation during a turn.

  Fields:
  - `name`: Tool name that was called
  - `args`: Arguments passed to the tool
  - `result`: Value returned by the tool
  """
  @type tool_call :: %{
          name: String.t(),
          args: map(),
          result: term()
        }

  @typedoc """
  A message sent to the LLM.

  Fields:
  - `role`: Message role (:system, :user, or :assistant)
  - `content`: Message content
  """
  @type message :: %{role: :system | :user | :assistant, content: String.t()}

  @typedoc """
  Turn struct capturing one LLM interaction cycle.

  One of `success?` will be true or false:
  - Success: Turn executed without errors
  - Failure: Turn encountered an error (result contains error info)
  """
  @type t :: %__MODULE__{
          number: pos_integer(),
          raw_response: String.t(),
          program: String.t() | nil,
          result: term(),
          prints: [String.t()],
          tool_calls: [tool_call()],
          memory: map(),
          success?: boolean(),
          messages: [message()] | nil,
          type: turn_type()
        }

  @doc """
  Creates a successful turn.

  ## Parameters

  - `number` - Turn sequence number (1-indexed)
  - `raw_response` - Full LLM output including reasoning
  - `program` - Parsed PTC-Lisp program, or nil if parsing failed
  - `result` - Execution result value
  - `params` - Optional map with:
    - `:prints` - Captured println output (default: [])
    - `:tool_calls` - Tool invocations made during this turn (default: [])
    - `:memory` - Accumulated definitions after this turn (default: %{})
    - `:messages` - Messages sent to the LLM for this turn (default: nil)
    - `:type` - Turn type: `:normal`, `:must_return`, or `:retry` (default: `:normal`)

  ## Examples

      iex> turn = PtcRunner.Turn.success(1, "```ptc-lisp\\n(+ 1 2)\\n```", "(+ 1 2)", 3)
      iex> turn.success?
      true
      iex> turn.number
      1
      iex> turn.result
      3

      iex> turn = PtcRunner.Turn.success(2, "raw", "(+ x y)", 30, %{prints: ["hello"], memory: %{x: 10}})
      iex> turn.prints
      ["hello"]
      iex> turn.memory
      %{x: 10}

      iex> turn = PtcRunner.Turn.success(3, "raw", "(return 42)", 42, %{type: :must_return})
      iex> turn.type
      :must_return

  """
  @spec success(pos_integer(), String.t(), String.t() | nil, term(), map()) :: t()
  def success(number, raw_response, program, result, params \\ %{}) do
    %__MODULE__{
      number: number,
      raw_response: raw_response,
      program: program,
      result: result,
      prints: Map.get(params, :prints, []),
      tool_calls: Map.get(params, :tool_calls, []),
      memory: Map.get(params, :memory, %{}),
      success?: true,
      messages: Map.get(params, :messages),
      type: Map.get(params, :type, :normal)
    }
  end

  @doc """
  Creates a failed turn.

  The `error` parameter contains error information (typically a map with `:reason` and `:message`).

  ## Parameters

  - `number` - Turn sequence number (1-indexed)
  - `raw_response` - Full LLM output including reasoning
  - `program` - Parsed PTC-Lisp program, or nil if parsing failed
  - `error` - Error information (typically a map with `:reason` and `:message`)
  - `params` - Optional map with:
    - `:prints` - Captured println output (default: [])
    - `:tool_calls` - Tool invocations made during this turn (default: [])
    - `:memory` - Memory state after this turn (default: %{})
    - `:messages` - Messages sent to the LLM for this turn (default: nil)
    - `:type` - Turn type: `:normal`, `:must_return`, or `:retry` (default: `:normal`)

  ## Examples

      iex> turn = PtcRunner.Turn.failure(2, "```ptc-lisp\\n(/ 1 0)\\n```", "(/ 1 0)", %{reason: :eval_error, message: "division by zero"}, %{memory: %{x: 10}})
      iex> turn.success?
      false
      iex> turn.result
      %{reason: :eval_error, message: "division by zero"}
      iex> turn.memory
      %{x: 10}

      iex> turn = PtcRunner.Turn.failure(3, "raw", "(return {:x 1})", %{reason: :validation_error}, %{type: :retry})
      iex> turn.type
      :retry

  """
  @spec failure(pos_integer(), String.t(), String.t() | nil, term(), map()) :: t()
  def failure(number, raw_response, program, error, params \\ %{}) do
    %__MODULE__{
      number: number,
      raw_response: raw_response,
      program: program,
      result: error,
      prints: Map.get(params, :prints, []),
      tool_calls: Map.get(params, :tool_calls, []),
      memory: Map.get(params, :memory, %{}),
      success?: false,
      messages: Map.get(params, :messages),
      type: Map.get(params, :type, :normal)
    }
  end
end
