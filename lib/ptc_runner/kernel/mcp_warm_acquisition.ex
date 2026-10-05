defmodule PtcRunner.Kernel.MCPWarmAcquisition do
  @moduledoc false
  alias PtcRunner.Kernel.{MCPBorrowToken, MCPRequestContext, MCPStdioTransport}

  def valid?(nil), do: true
  def valid?(%MCPRequestContext{pid: pid}), do: is_pid(pid)
  def valid?(%MCPStdioTransport{pid: pid}), do: is_pid(pid)
  def valid?(_), do: false

  def supported?(%{name: name, destination: destination}, catalog) do
    case catalog.descriptors[name] do
      %{source: :mcp, authorization_mode: mode} -> mode != :oauth and destination == :mission
      _ -> true
    end
  end

  def bind_transport(transport, %{mcp_borrow_token: token}),
    do: %{transport | handle: with_borrow(transport.handle, token)}

  def bind_transport(transport, _context), do: transport

  defp with_borrow(%MCPRequestContext{} = handle, token),
    do: MCPRequestContext.with_borrow(handle, token)

  defp with_borrow(%MCPStdioTransport{} = handle, token),
    do: MCPStdioTransport.with_borrow(handle, token)

  def bind(providers, token) do
    providers =
      Enum.reduce([:workflow, :mission], providers, fn destination, acc ->
        update_in(acc, [destination, :capabilities], &bind_capabilities(&1, token))
      end)

    update_in(providers, [:mission, :by_occurrence], fn occurrences ->
      Map.new(occurrences, fn {index, capabilities} ->
        {index, bind_capabilities(capabilities, token)}
      end)
    end)
  end

  defp bind_capabilities(capabilities, token) do
    Enum.map(capabilities, fn capability ->
      callback = Map.get(capability, :callback)

      if is_function(callback, 2) do
        %{
          capability
          | callback: fn args, context ->
              callback.(args, Map.put(context, :mcp_borrow_token, token))
            end
        }
      else
        capability
      end
    end)
  end

  def monitors(providers),
    do: Enum.map(Map.get(providers, :mcp_transports, []), &Process.monitor(&1.pid))

  def settle(providers, token, deadline) do
    # The shared atomic seal closes admission on every transport before any wait.
    :ok = MCPBorrowToken.seal(token)

    Enum.reduce(Map.get(providers, :mcp_transports, []), :ok, fn handle, result ->
      settled = settle_handle(with_borrow(handle, token), deadline)
      if result == :ok and settled == :ok, do: :ok, else: {:error, :provider_cleanup_failed}
    end)
  end

  defp settle_handle(%MCPRequestContext{} = handle, deadline),
    do: MCPRequestContext.settle(handle, deadline)

  defp settle_handle(%MCPStdioTransport{} = handle, deadline),
    do: MCPStdioTransport.settle(handle, deadline)
end
