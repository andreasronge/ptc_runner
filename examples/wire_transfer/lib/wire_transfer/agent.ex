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
      1. Prepare the wire transfer using `prepare_wire` — returns a hold_id
      2. Request manager approval using `request_approval`
      3. Check the journal for the manager's decision using task ID
         `(str "manager_decision_" recipient "_" amount)` — returns nil if not yet decided
         - If nil, return `{:status :waiting :msg "Pending manager approval"}`
         - If `:approved`, execute the wire using `execute_wire` (pass the hold_id from step 1)
         - If `:rejected`, cancel the hold using `cancel_hold`
      4. Always execute ALL steps in order — completed tasks return cached results instantly.

      ## Task IDs
      EVERY tool call MUST be wrapped in `(task ...)` for idempotency.
      Use `(str ...)` to build semantic task IDs, e.g.:
      `(task (str "prepare_wire_" recipient "_" amount) (tool/prepare_wire ...))`
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
