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

  test "guarded heap exhaustion keeps its classification across startup" do
    for _iteration <- 1..100 do
      assert {:error, :heap_exceeded} =
               BoundedWorker.run(fn -> Enum.to_list(1..1_000_000) end,
                 timeout_ms: 1_000,
                 max_heap_words: 10_000,
                 cancel_with_caller: true
               )
    end
  end

  test "caller guard never copies the bounded callback closure" do
    test = self()
    payload = List.duplicate(:captured, 100_000)

    caller =
      spawn(fn ->
        receive do
          :run ->
            result =
              BoundedWorker.run(
                fn ->
                  send(test, {:bounded_worker_started, self()})

                  receive do
                    :finish -> length(payload)
                  end
                end,
                timeout_ms: 5_000,
                max_heap_words: 1_000_000,
                cancel_with_caller: true
              )

            send(test, {:bounded_worker_result, result})
        end
      end)

    assert :erlang.trace(caller, true, [:procs, {:tracer, test}]) == 1
    send(caller, :run)

    assert_receive {:trace, ^caller, :spawn, guard, _initial_call}
    assert_receive {:bounded_worker_started, worker}
    assert {:total_heap_size, guard_heap_words} = Process.info(guard, :total_heap_size)
    assert guard_heap_words < 10_000

    send(worker, :finish)
    assert_receive {:bounded_worker_result, {:ok, 100_000}}
  end

  test "initial callback closure must fit the worker heap before execution" do
    test = self()
    payload = List.duplicate(:captured, 100_000)

    assert {:error, :heap_exceeded} =
             BoundedWorker.run(
               fn ->
                 send(test, {:oversized_callback_ran, length(payload)})
                 :done
               end,
               timeout_ms: 1_000,
               max_heap_words: 10_000,
               cancel_with_caller: true
             )

    refute_receive {:oversized_callback_ran, _size}
  end

  test "completion after the absolute deadline cannot win from the mailbox" do
    test = self()

    caller =
      spawn(fn ->
        result =
          BoundedWorker.run(
            fn ->
              send(test, {:late_worker_ready, self()})

              receive do
                :finish ->
                  send(test, {:late_worker_finished, self()})
                  :late
              end
            end,
            timeout_ms: 10,
            max_heap_words: 10_000,
            cancel_with_caller: true
          )

        send(test, {:late_worker_result, result})
      end)

    assert_receive {:late_worker_ready, worker}
    assert true = :erlang.suspend_process(caller)
    timer = :erlang.start_timer(20, self(), :deadline_elapsed)
    assert_receive {:timeout, ^timer, :deadline_elapsed}
    send(worker, :finish)
    assert_receive {:late_worker_finished, ^worker}
    assert true = :erlang.resume_process(caller)
    assert_receive {:late_worker_result, {:error, :timeout}}
  end

  test "a worker delayed past startup deadline never invokes the callback" do
    test = self()

    caller =
      spawn(fn ->
        receive do
          :run ->
            result =
              BoundedWorker.run(
                fn ->
                  send(test, :expired_callback_ran)
                  :done
                end,
                timeout_ms: 200,
                max_heap_words: 10_000,
                cancel_with_caller: true,
                startup_fault_hook: fn worker ->
                  send(test, {:startup_worker, worker})

                  receive do
                    :continue_startup -> :ok
                  end
                end
              )

            send(test, {:expired_start_result, result})
        end
      end)

    assert :erlang.trace(caller, true, [:send, {:tracer, test}]) == 1
    send(caller, :run)
    assert_receive {:startup_worker, worker}

    try do
      assert true = :erlang.suspend_process(worker)
      send(caller, :continue_startup)
      assert_receive {:trace, ^caller, :send, {_start_ref, :run}, ^worker}
      assert true = :erlang.suspend_process(caller)
      worker_ref = Process.monitor(worker)

      timer = :erlang.start_timer(250, self(), :startup_deadline_elapsed)
      assert_receive {:timeout, ^timer, :startup_deadline_elapsed}
      assert true = :erlang.resume_process(worker)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}
      refute_receive :expired_callback_ran

      assert true = :erlang.resume_process(caller)
      assert_receive {:expired_start_result, {:error, :timeout}}
    after
      send(caller, :continue_startup)
      resume_if_suspended(worker)
      resume_if_suspended(caller)
      if Process.alive?(caller), do: Process.exit(caller, :kill)
    end
  end

  test "startup timeouts leave no guard acknowledgements in the caller mailbox" do
    for _iteration <- 1..20 do
      assert {:error, :timeout} =
               BoundedWorker.run(fn -> :unexpected end,
                 timeout_ms: 0,
                 max_heap_words: 10_000,
                 cancel_with_caller: true
               )
    end

    assert {:messages, messages} = Process.info(self(), :messages)

    refute Enum.any?(messages, fn
             {_guard_ref, :armed} -> true
             _other -> false
           end)
  end

  test "termination drains a result already ordered before worker DOWN" do
    parent = self()
    reply_alias = Process.alias()
    reply_ref = make_ref()

    {worker, monitor_ref} =
      spawn_monitor(fn ->
        send(reply_alias, {reply_ref, System.monotonic_time(:millisecond), :late_result})
        send(parent, :late_result_sent)

        receive do
          :never -> :unexpected
        end
      end)

    assert_receive :late_result_sent
    assert :ok = BoundedWorker.terminate(worker, monitor_ref, reply_alias, reply_ref)
    refute Process.alive?(worker)
    refute_receive {^reply_ref, _completed_at_ms, :late_result}
    refute_receive {:DOWN, ^monitor_ref, :process, ^worker, _reason}
  end

  test "caller kill propagates to an opted-in bounded worker" do
    test = self()

    caller =
      spawn(fn ->
        BoundedWorker.run(
          fn ->
            send(test, {:bounded_worker, self()})

            receive do
              :never -> :unexpected
            end
          end,
          timeout_ms: 60_000,
          # This case isolates caller cancellation, not heap enforcement. A
          # 10k-word worker can hit its heap limit before the test installs
          # its monitor under full-suite scheduler pressure and report
          # `:noproc` instead of the cancellation reason being asserted.
          max_heap_words: 100_000,
          cancel_with_caller: true
        )
      end)

    assert_receive {:bounded_worker, worker}
    worker_ref = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
  end

  test "a separate cancellation owner terminates bounded work" do
    parent = self()
    cancellation_owner = spawn(fn -> receive do: (:stop -> :ok) end)

    caller =
      spawn(fn ->
        result =
          BoundedWorker.run(
            fn ->
              send(parent, {:cancelled_worker, self()})
              receive do: (:never -> :unexpected)
            end,
            timeout_ms: 5_000,
            max_heap_words: 10_000,
            cancel_with: cancellation_owner
          )

        send(parent, {:cancelled_result, result})
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:cancelled_worker, worker}
    worker_ref = Process.monitor(worker)
    Process.exit(cancellation_owner, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    assert_receive {:cancelled_result, {:error, :cancelled}}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
  end

  test "successful linked work leaves no exit message" do
    assert {:ok, :done} =
             BoundedWorker.run(fn -> :done end,
               timeout_ms: 1_000,
               max_heap_words: 10_000,
               cancel_with_caller: true
             )

    refute_receive {:EXIT, _pid, _reason}
  end

  test "caller kill during timeout cleanup still terminates linked work" do
    test = self()

    caller =
      spawn(fn ->
        BoundedWorker.run(
          fn ->
            send(test, {:timeout_worker, self()})

            receive do
              :never -> :unexpected
            end
          end,
          # Guarded startup shares this deadline. 1ms expires before the
          # callback can send under CI scheduler pressure, so cleanup
          # arrives with no worker pid to monitor.
          timeout_ms: 50,
          max_heap_words: 100_000,
          cancel_with_caller: true,
          timeout_cleanup_hook: fn ->
            send(test, {:timeout_cleanup, self()})

            receive do
              :continue_cleanup -> :ok
            end
          end
        )
      end)

    assert_receive {:timeout_worker, worker}
    worker_ref = Process.monitor(worker)
    assert_receive {:timeout_cleanup, ^caller}
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
  end

  defp resume_if_suspended(pid) do
    if Process.alive?(pid) and Process.info(pid, :status) == {:status, :suspended},
      do: :erlang.resume_process(pid)
  end
end
