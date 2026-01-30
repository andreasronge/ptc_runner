defmodule WireTransfer.Agent do
  @moduledoc """
  SubAgent definition for the wire transfer Navigator.
  """
  alias PtcRunner.SubAgent
  alias WireTransfer.Tools

  @doc """
  Returns a new wire transfer SubAgent configured with the Navigator pattern.
  """
  def new do
    SubAgent.new(
      prompt: """
      You are a banking agent processing wire transfers.

      **Current request:** Transfer ${{amount}} to {{recipient}}.

      ## Steps
      1. Prepare the wire transfer using `prepare_wire`
      2. Request manager approval using `request_approval`
      3. Check the journal for the manager decision task
         - If the decision is not yet in the journal, return `{:status :waiting :msg "Pending manager approval"}`
         - If approved, execute the wire using `execute_wire` (pass the hold_id from step 1)
         - If rejected, cancel the hold using `cancel_hold`

      ## Task IDs
      IMPORTANT: `(task id expr)` requires a string literal ID — you cannot use `(str ...)`.
      Read data/recipient and data/amount, then write the actual values into the ID string.

      For example, if recipient is "bob" and amount is 5000, use:
      - `(task "prepare_wire_bob_5000" ...)`
      - `(task "request_approval_bob_5000" ...)`
      - `(task "manager_decision_bob_5000" nil)` — reads external decision from journal
      - `(task "execute_wire_bob_5000" ...)`
      - `(task "cancel_wire_bob_5000" ...)`
      """,
      signature: "(recipient :string, amount :int) -> {status :keyword}",
      tools: %{
        "prepare_wire" => &Tools.prepare_wire/1,
        "request_approval" => &Tools.request_approval/1,
        "execute_wire" => &Tools.execute_wire/1,
        "cancel_hold" => &Tools.cancel_hold/1
      },
      max_turns: 5
    )
  end
end
