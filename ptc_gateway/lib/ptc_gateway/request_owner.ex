defmodule PtcGateway.RequestOwner do
  @moduledoc false

  @spec start(pid(), pid(), pos_integer(), map(), map()) :: pid()
  def start(connection, admission, id, tool, arguments) do
    spawn_link(fn ->
      conn_ref = Process.monitor(connection)

      receive do
        :go ->
          run(connection, admission, id, tool, arguments, conn_ref)

        :abort ->
          Process.demonitor(conn_ref, [:flush])
          :ok

        {:DOWN, ^conn_ref, :process, ^connection, _reason} ->
          :ok
      end
    end)
  end

  defp run(connection, admission, id, tool, arguments, conn_ref) do
    result = invoke(tool.call, arguments)
    Process.demonitor(conn_ref, [:flush])
    send(connection, {:request_finished, self(), id, result})
    PtcGateway.Admission.checkin(admission, self())
  end

  defp invoke(call, arguments) when is_function(call, 1) do
    call.(arguments)
  rescue
    _exception -> {:error, :execution}
  catch
    _kind, _reason -> {:error, :execution}
  end
end
