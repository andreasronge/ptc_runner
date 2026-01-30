defmodule WireTransfer.Tools do
  @moduledoc """
  Mock banking tools for the wire transfer example.

  Each tool simulates a side effect (reserving funds, requesting approval, etc.)
  and returns a deterministic result for demonstration purposes.
  """

  @doc """
  Prepare a wire transfer by reserving funds. Returns a hold ID.
  """
  @spec prepare_wire(%{to: String.t(), amount: integer()}) :: String.t()
  def prepare_wire(%{"to" => to, "amount" => amount}) do
    hold_id = "hold_#{to}_#{amount}"
    IO.puts("[TOOL] prepare_wire: Reserved $#{amount} for #{to} → #{hold_id}")
    hold_id
  end

  @doc """
  Request manager approval for a transfer. Returns a request ID.
  """
  @spec request_approval(%{type: String.t(), amount: integer(), to: String.t()}) :: map()
  def request_approval(%{"to" => to, "amount" => amount}) do
    request_id = "req_#{to}_#{amount}"
    IO.puts("[TOOL] request_approval: Approval requested → #{request_id}")
    %{"request_id" => request_id}
  end

  @doc """
  Execute a prepared wire transfer. Returns a wire confirmation ID.
  """
  @spec execute_wire(%{hold_id: String.t(), to: String.t(), amount: integer()}) :: String.t()
  def execute_wire(%{"hold_id" => hold_id, "to" => to, "amount" => amount}) do
    wire_id = "wire_#{to}_#{amount}"
    IO.puts("[TOOL] execute_wire: Transferred $#{amount} to #{to} (hold: #{hold_id}) → #{wire_id}")
    wire_id
  end

  @doc """
  Cancel a hold and release reserved funds.
  """
  @spec cancel_hold(%{hold_id: String.t()}) :: String.t()
  def cancel_hold(%{"hold_id" => hold_id}) do
    IO.puts("[TOOL] cancel_hold: Released hold #{hold_id}")
    "released"
  end
end
