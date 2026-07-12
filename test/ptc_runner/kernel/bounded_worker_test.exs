defmodule PtcRunner.Kernel.BoundedWorkerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.BundleCompiler

  test "timeout kills the worker without leaking monitor or result messages" do
    parent = self()

    assert {:error, :timeout} =
             BoundedWorker.run(
               fn ->
                 send(parent, {:bounded_worker, self()})

                 receive do
                   :never -> :unexpected
                 end
               end,
               timeout_ms: 1,
               max_heap_words: 10_000
             )

    assert_receive {:bounded_worker, worker}
    refute Process.alive?(worker)
    refute_receive {:DOWN, _ref, :process, _pid, _reason}
    refute_receive {_reply_ref, _result}
  end

  test "result boundaries independently enforce artifact and diagnostic bytes" do
    assert {:error, %{reason: :bundle_artifact_exceeded}} =
             BundleCompiler.enforce_result({:ok, String.duplicate("x", 100)}, 10, 1_000)

    assert {:error, %{reason: :bundle_diagnostic_exceeded}} =
             BundleCompiler.enforce_result(
               {:error, %{reason: :fixture, details: String.duplicate("x", 100)}},
               1_000,
               10
             )
  end

  test "heap exhaustion is classified independently from timeout" do
    assert {:error, :heap_exceeded} =
             BoundedWorker.run(fn -> Enum.to_list(1..1_000_000) end,
               timeout_ms: 1_000,
               max_heap_words: 10_000
             )
  end

  test "termination drains a result already ordered before worker DOWN" do
    parent = self()
    reply_alias = Process.alias()
    reply_ref = make_ref()

    {worker, monitor_ref} =
      spawn_monitor(fn ->
        send(reply_alias, {reply_ref, :late_result})
        send(parent, :late_result_sent)

        receive do
          :never -> :unexpected
        end
      end)

    assert_receive :late_result_sent
    assert :ok = BoundedWorker.terminate(worker, monitor_ref, reply_alias, reply_ref)
    refute Process.alive?(worker)
    refute_receive {^reply_ref, :late_result}
    refute_receive {:DOWN, ^monitor_ref, :process, ^worker, _reason}
  end
end
