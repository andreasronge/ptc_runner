defmodule PtcViewer.LiveStoreTest do
  use ExUnit.Case, async: true

  alias PtcViewer.LiveStore

  setup do
    {:ok, store} = LiveStore.start(self())
    %{store: store}
  end

  test "stores the latest frame per run and snapshots oldest-first", %{store: store} do
    assert :ok = LiveStore.put_frame(store, "run-a", %{"seq" => 0, "phase" => "running"})
    assert :ok = LiveStore.put_frame(store, "run-b", %{"seq" => 0, "phase" => "running"})
    assert :ok = LiveStore.put_frame(store, "run-a", %{"seq" => 1, "phase" => "ok"})

    assert [%{"run_id" => "run-a", "seq" => 1, "phase" => "ok"}, %{"run_id" => "run-b"}] =
             LiveStore.snapshot(store)
  end

  test "subscribe returns the encoded snapshot and then delivers live frames", %{store: store} do
    :ok = LiveStore.put_frame(store, "run-a", %{"seq" => 0})

    {:ok, [snapshot_json]} = LiveStore.subscribe(store, self())
    assert %{"run_id" => "run-a", "seq" => 0} = Jason.decode!(snapshot_json)

    :ok = LiveStore.put_frame(store, "run-a", %{"seq" => 1})
    assert_receive {:live_frame, live_json}
    assert %{"run_id" => "run-a", "seq" => 1} = Jason.decode!(live_json)
  end

  test "a dead subscriber is dropped without affecting frame acceptance", %{store: store} do
    {subscriber, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, _reason}

    {:ok, _snapshot} = LiveStore.subscribe(store, subscriber)
    assert :ok = LiveStore.put_frame(store, "run-a", %{"seq" => 0})
  end

  test "eviction drops the oldest ended run and never a live one", %{store: store} do
    for index <- 1..12 do
      :ok = LiveStore.put_frame(store, "run-#{index}", %{"seq" => 0, "phase" => "ok"})
    end

    :ok = LiveStore.put_frame(store, "run-live", %{"seq" => 0, "phase" => "running"})

    run_ids = store |> LiveStore.snapshot() |> Enum.map(& &1["run_id"])
    assert length(run_ids) == 12
    refute "run-1" in run_ids
    assert "run-live" in run_ids
  end

  test "rejects a frame that cannot encode", %{store: store} do
    assert {:error, :invalid_frame} = LiveStore.put_frame(store, "run-a", %{"pid" => self()})
    assert LiveStore.snapshot(store) == []
  end

  test "stops when its owner goes down" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, store} = LiveStore.start(self())
        send(parent, {:store, store})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:store, store}
    store_ref = Process.monitor(store)
    send(owner, :finish)
    assert_receive {:DOWN, ^store_ref, :process, ^store, {:shutdown, :owner_down}}
  end

  test "launch gate: single-flight, result captured from exit reason", %{store: store} do
    assert %{status: "idle"} = LiveStore.launch_status(store)

    gate = self()

    :ok =
      LiveStore.begin_launch(store, fn ->
        send(gate, {:launch_started, self()})

        receive do
          :release -> {0, "done"}
        end
      end)

    assert_receive {:launch_started, launch_pid}
    assert %{status: "running"} = LiveStore.launch_status(store)
    assert {:error, :launch_running} = LiveStore.begin_launch(store, fn -> {0, ""} end)

    launch_ref = Process.monitor(launch_pid)
    send(launch_pid, :release)
    assert_receive {:DOWN, ^launch_ref, :process, ^launch_pid, {:launch_result, {0, "done"}}}

    assert eventually(fn -> LiveStore.launch_status(store) == %{status: "ok"} end)
  end

  test "launch failure surfaces the output tail", %{store: store} do
    :ok = LiveStore.begin_launch(store, fn -> {1, "boom tail"} end)

    assert eventually(fn ->
             match?(
               %{status: "error", output_tail: "exit 1: boom tail"},
               LiveStore.launch_status(store)
             )
           end)
  end

  # Bounded convergence poll for state that settles on a monitor DOWN whose
  # delivery order relative to this test process is not guaranteed. No timing
  # assumption: each probe is a synchronous call, and the loop exits as soon
  # as the store has processed its DOWN.
  defp eventually(fun, attempts \\ 200)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      receive do
      after
        5 -> :ok
      end

      eventually(fun, attempts - 1)
    end
  end
end
