defmodule PtcRunner.Labs.ServingHost do
  @moduledoc false
  use GenServer

  # Bounded lab recovery of PR #1482's request-owner handoff. The fixture
  # supplies HTTP framing; this is not an MCP endpoint or deployable server.
  def start_link(limit), do: GenServer.start_link(__MODULE__, limit)
  def snapshot(host), do: GenServer.call(host, :snapshot)

  def serve(host, socket, run) do
    case GenServer.call(host, {:admit, self(), run}) do
      {:ok, owner} ->
        try do
          :ok = :inet.setopts(socket, active: :once)

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n: ready\n\n"
            )

          send(owner, :go)
          await(socket, owner)
        after
          Process.unlink(owner)
          Process.exit(owner, :kill)
        end

      :full ->
        :gen_tcp.send(socket, "HTTP/1.1 503 Busy\r\nContent-Length: 0\r\n\r\n")
    end
  end

  @impl true
  def init(limit) do
    Process.flag(:trap_exit, true)
    {:ok, %{limit: limit, owners: %{}}}
  end

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, map_size(state.owners), state}

  def handle_call({:admit, connection, run}, _, state) do
    if map_size(state.owners) < state.limit do
      owner =
        spawn_link(fn ->
          Process.link(connection)

          receive do
            :go -> send(connection, {:finished, self(), run.()})
          end
        end)

      ref = Process.monitor(owner)
      {:reply, {:ok, owner}, %{state | owners: Map.put(state.owners, ref, owner)}}
    else
      {:reply, :full, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: {:noreply, %{state | owners: Map.delete(state.owners, ref)}}

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    Enum.each(state.owners, fn {_, owner} -> Process.exit(owner, :kill) end)
  end

  defp await(socket, owner) do
    receive do
      {:tcp_closed, ^socket} -> :ok
      {:tcp_error, ^socket, _} -> :ok
      {:tcp, ^socket, _} -> :ok
      {:finished, ^owner, _result} -> :gen_tcp.send(socket, "data: complete\n\n")
    after
      30_000 -> :ok
    end
  end
end
