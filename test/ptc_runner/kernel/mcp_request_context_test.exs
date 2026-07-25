defmodule PtcRunner.Kernel.MCPRequestContextTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.MCPRequestContext

  test "owner death closes the credential context" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    {:ok, context} = context(owner)
    context_ref = Process.monitor(context.pid)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^context_ref, :process, _pid, :normal}
  end

  test "close kills and drains an in-flight request caller" do
    {:ok, context} = context(self())
    parent = self()

    caller =
      spawn(fn ->
        assert {:ok, _request} = MCPRequestContext.begin_request(context)
        send(parent, :request_started)
        receive do: (:never -> :ok)
      end)

    caller_ref = Process.monitor(caller)
    context_ref = Process.monitor(context.pid)
    assert_receive :request_started

    assert :ok = MCPRequestContext.close(context)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    assert_receive {:DOWN, ^context_ref, :process, _pid, :normal}
  end

  test "every concurrent close waits for the same completed shutdown" do
    {:ok, context} = context(self())
    parent = self()

    for index <- 1..64 do
      spawn(fn ->
        assert {:ok, _request} = MCPRequestContext.begin_request(context)
        send(parent, {:request_started, index})
        receive do: (:never -> :ok)
      end)
    end

    for index <- 1..64, do: assert_receive({:request_started, ^index})

    context_ref = Process.monitor(context.pid)

    closers =
      for index <- 1..8 do
        Task.async(fn ->
          result = MCPRequestContext.close(context)
          {index, result, Process.alive?(context.pid)}
        end)
      end

    assert_receive {:DOWN, ^context_ref, :process, _pid, :normal}

    assert Enum.map(closers, &Task.await/1)
           |> Enum.all?(fn {_index, result, alive?} -> result == :ok and not alive? end)
  end

  defp context(owner) do
    MCPRequestContext.start(
      owner: owner,
      endpoint: "https://example.com/mcp",
      headers: [{"authorization", "Bearer PRIVATE"}],
      timeout_ms: 1_000
    )
  end
end
