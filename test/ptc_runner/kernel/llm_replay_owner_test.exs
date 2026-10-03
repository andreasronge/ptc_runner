defmodule PtcRunner.Kernel.LLMReplayOwnerTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.Eventually

  alias PtcRunner.Kernel.LLMReplayOwner

  test "shared immutable fixtures advance by tails and reclaim each run cursor" do
    entries = %{"key" => [%{"turn" => 1}, %{"turn" => 2}]}
    {:ok, replay} = LLMReplayOwner.start(entries, self())
    on_exit(fn -> LLMReplayOwner.stop(replay) end)

    scope =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(scope)

    assert {:error, :unmatched} = LLMReplayOwner.take(replay, "missing", scope)
    assert :sys.get_state(replay).cursors == %{}
    assert {:ok, %{"turn" => 1}} = LLMReplayOwner.take(replay, "key", scope)
    state = :sys.get_state(replay)
    assert state.entries == entries
    assert state.cursors[scope].remaining["key"] == [%{"turn" => 2}]
    assert {:ok, %{"turn" => 1}} = LLMReplayOwner.take(replay, "key", self())
    assert {:ok, %{"turn" => 2}} = LLMReplayOwner.take(replay, "key", scope)
    assert {:error, :exhausted} = LLMReplayOwner.take(replay, "key", scope)
    send(scope, :stop)
    assert_receive {:DOWN, ^ref, :process, ^scope, :normal}
    assert_eventually(fn -> not Map.has_key?(:sys.get_state(replay).cursors, scope) end)
    state = :sys.get_state(replay)
    refute Map.has_key?(state.cursors, scope)
    assert state.entries == entries
    assert {:ok, %{"turn" => 2}} = LLMReplayOwner.take(replay, "key", self())
  end

  test "concurrent calls within a run consume every response exactly once" do
    entries = %{"key" => Enum.map(1..200, &%{"turn" => &1})}
    {:ok, replay} = LLMReplayOwner.start(entries, self())
    on_exit(fn -> LLMReplayOwner.stop(replay) end)
    scope = self()

    turns =
      1..240
      |> Task.async_stream(fn _ -> LLMReplayOwner.take(replay, "key", scope) end,
        max_concurrency: 32
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(turns, &(&1 == {:error, :exhausted})) == 40

    assert turns
           |> Enum.flat_map(fn
             {:ok, %{"turn" => turn}} -> [turn]
             {:error, :exhausted} -> []
           end)
           |> Enum.sort() == Enum.to_list(1..200)
  end

  test "installation owner exit stops the replay process" do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, replay} = LLMReplayOwner.start(%{"key" => [%{}]}, owner)
    ref = Process.monitor(replay)
    assert {:ok, %{}} = LLMReplayOwner.take(replay, "key", self())
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^replay, :normal}
    assert {:error, :unavailable} = LLMReplayOwner.take(replay, "key", self())
  end
end
