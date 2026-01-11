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

  ## Constructors

  Use `success/7` or `failure/7` to create turns - don't construct the struct directly.
  The constructors ensure `success?` is set correctly.

  See [Message History Optimization](docs/specs/message-history-optimization-requirements.md) for context.
  """

  defstruct [
    :number,
    :raw_response,
    :program,
    :result,
    :prints,
    :tool_calls,
    :memory,
    :success?
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
          success?: boolean()
        }

  @doc """
  Creates a successful turn.

  ## Examples

      iex> turn = PtcRunner.Turn.success(1, "```ptc-lisp\\n(+ 1 2)\\n```", "(+ 1 2)", 3, [], [], %{})
      iex> turn.success?
      true
      iex> turn.number
      1
      iex> turn.result
      3

  """
  @spec success(
          pos_integer(),
          String.t(),
          String.t() | nil,
          term(),
          [String.t()],
          [tool_call()],
          map()
        ) :: t()
  def success(number, raw_response, program, result, prints, tool_calls, memory) do
    %__MODULE__{
      number: number,
      raw_response: raw_response,
      program: program,
      result: result,
      prints: prints,
      tool_calls: tool_calls,
      memory: memory,
      success?: true
    }
  end

  @doc """
  Creates a failed turn.

  The `error` parameter contains error information (typically a map with `:reason` and `:message`).

  ## Examples

      iex> turn = PtcRunner.Turn.failure(2, "```ptc-lisp\\n(/ 1 0)\\n```", "(/ 1 0)", %{reason: :eval_error, message: "division by zero"}, [], [], %{x: 10})
      iex> turn.success?
      false
      iex> turn.result
      %{reason: :eval_error, message: "division by zero"}
      iex> turn.memory
      %{x: 10}

  """
  @spec failure(
          pos_integer(),
          String.t(),
          String.t() | nil,
          term(),
          [String.t()],
          [tool_call()],
          map()
        ) :: t()
  def failure(number, raw_response, program, error, prints, tool_calls, memory) do
    %__MODULE__{
      number: number,
      raw_response: raw_response,
      program: program,
      result: error,
      prints: prints,
      tool_calls: tool_calls,
      memory: memory,
      success?: false
    }
  end
end
