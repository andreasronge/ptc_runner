defmodule PtcRunner.SubAgent.Compaction.Context do
  @moduledoc """
  Read-only context passed to compaction strategies.

  Locks in the shape that future custom-strategy APIs will receive so that
  strategies never see the full loop `%State{}`. Phase 1 has only one internal
  caller (the loop's `build_llm_messages/3`), but the struct shape is fixed
  here intentionally.

  Fields:

  - `turn` — the turn that is about to start (1-indexed).
  - `max_turns` — agent's `max_turns` setting.
  - `retry_phase?` — `true` while the loop is in a retry/validation phase.
  - `memory` — the agent's accumulated memory (read-only view).
  - `token_counter` — 1-arity function from message content to estimated tokens.
  """

  @enforce_keys [:turn, :max_turns, :token_counter]
  defstruct turn: 1,
            max_turns: 1,
            retry_phase?: false,
            memory: nil,
            token_counter: nil

  @type t :: %__MODULE__{
          turn: pos_integer(),
          max_turns: pos_integer(),
          retry_phase?: boolean(),
          memory: map() | nil,
          token_counter: (String.t() -> non_neg_integer())
        }
end
