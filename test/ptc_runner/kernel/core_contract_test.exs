defmodule PtcRunner.Kernel.CoreContractTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.Eventually, only: [assert_eventually: 1]

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.Program
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.ProviderSession
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.ResultArtifact
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.SourceCheck
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.TestSupport.ProviderSessionFixture
  alias PtcRunner.TestSupport.TestHelpers

  @input_schema %{"type" => "object", "additionalProperties" => true}

  test "environment constructors reject duplicate and mission-reserved capability names" do
    assert {:ok, capability} =
             Capability.new(
               name: "read",
               input_schema: @input_schema,
               callback: fn _ -> {:ok, %{"ok" => true}} end
             )

    assert {:error, :duplicate_capability} =
             WorkflowEnvironment.new(capabilities: [capability, capability])

    assert {:ok, reserved} =
             Capability.new(
               name: "kernel-eval",
               input_schema: @input_schema,
               callback: fn _ -> {:ok, nil} end
             )

    assert {:error, :reserved_capability} = MissionEnvironment.new(capabilities: [reserved])

    assert {:ok, source_check} =
             Capability.new(
               name: "kernel-check-source",
               input_schema: @input_schema,
               callback: fn _ -> {:ok, nil} end
             )

    assert {:error, :reserved_capability} =
             WorkflowEnvironment.new(capabilities: [source_check])

    assert {:error, :reserved_capability} = MissionEnvironment.new(capabilities: [source_check])
  end

  test "capability quota reservation is total and per-name atomic" do
    {:ok, limits} =
      Limits.new(workflow_capability_calls: 1, workflow_capability_calls_per_name: 1)

    {:ok, state} = RunState.start(limits)

    assert :ok = RunState.reserve_capability(state, :workflow, "read")
    assert {:error, :limit_exceeded} = RunState.reserve_capability(state, :workflow, "read")
    assert {:error, :limit_exceeded} = RunState.reserve_capability(state, :workflow, "other")
  end

  test "run state preserves a supplied absolute deadline instead of resetting it" do
    limits = Limits.defaults()

    expired =
      Deadline.new(
        limits.run_duration_ms,
        System.monotonic_time(:millisecond) - limits.run_duration_ms - 1
      )

    assert {:ok, state} = RunState.start(limits, run_deadline: expired)
    assert RunState.remaining_ms(state) == 0
    refute RunState.open?(state)
    assert :ok = RunState.stop(state)
  end

  test "a caller cannot hold two capability reservations at once" do
    {:ok, state} = RunState.start(Limits.defaults())

    assert :ok = RunState.reserve_capability(state, :workflow, "read")
    assert {:error, :reservation_held} = RunState.reserve_capability(state, :workflow, "other")
    assert :ok = RunState.release_provider_slot(state)
    assert :ok = RunState.reserve_capability(state, :workflow, "other")
  end

  test "only one evaluation lease is granted and failed candidates preserve memory" do
    {:ok, limits} = Limits.new(subordinate_evaluations: 2, evaluation_memory_bytes: 1_000)
    {:ok, state} = RunState.start(limits)
    assert {:ok, %{}, [], lease} = RunState.reserve_evaluation(state, "default", :fail_fast)
    assert {:error, :busy} = RunState.reserve_evaluation(state, "default", :fail_fast)
    assert :ok = RunState.release_evaluation(state, lease)
    assert {:ok, %{}, [], next_lease} = RunState.reserve_evaluation(state, "default", :fail_fast)
    assert :ok = RunState.commit_evaluation(state, next_lease, %{"x" => 42}, [41])
    assert %{evaluation_memory_bytes: memory_bytes} = RunState.usage(state)
    assert memory_bytes > 0

    assert %{
             defined_count: 1,
             history_count: 1,
             memory_bytes: ^memory_bytes,
             history_bytes: history_bytes,
             bytes: combined_bytes
           } = RunState.evaluation_memory_summary(state)

    assert history_bytes > 0
    assert combined_bytes == memory_bytes + history_bytes
  end

  test "source-check reservations are independently bounded and detect continuation changes" do
    {:ok, limits} = Limits.new(subordinate_source_checks: 2)
    {:ok, state} = RunState.start(limits)

    assert {:ok, %{}, revision} = RunState.reserve_source_check(state, "default")
    assert :ok = RunState.finish_source_check(state, "default", revision)

    assert {:ok, %{}, stale_revision} = RunState.reserve_source_check(state, "default")
    assert {:ok, %{}, [], lease} = RunState.reserve_evaluation(state, "default", :fail_fast)
    assert :ok = RunState.commit_evaluation(state, lease, %{"retained" => 42}, [])
    assert {:error, :stale} = RunState.finish_source_check(state, "default", stale_revision)
    assert {:error, :limit_exceeded} = RunState.reserve_source_check(state, "default")

    assert %{subordinate_source_checks: 2} = RunState.usage(state)
  end

  test "source checks refuse an active evaluation lease without consuming quota" do
    {:ok, state} = RunState.start(Limits.defaults())
    assert {:ok, %{}, [], lease} = RunState.reserve_evaluation(state, "default", :fail_fast)
    assert {:error, :busy} = RunState.reserve_source_check(state, "default")
    assert %{subordinate_source_checks: 0} = RunState.usage(state)
    assert :ok = RunState.release_evaluation(state, lease)
  end

  test "evaluation status waits for its provider and cannot leak into the next lease" do
    parent = self()
    {:ok, state} = RunState.start(Limits.defaults())

    evaluation_owner =
      spawn_link(fn ->
        {:ok, %{}, [], lease} = RunState.reserve_evaluation(state, "default", :fail_fast)
        send(parent, {:evaluation_ready, self(), lease})

        receive do
          :release ->
            status = RunState.release_evaluation_status(state, lease)
            send(parent, {:evaluation_released, status})
        end
      end)

    assert_receive {:evaluation_ready, ^evaluation_owner, lease}

    {:ok, blocked} =
      Capability.new(
        name: "blocked",
        effect: :read,
        input_schema: @input_schema,
        callback: fn _ ->
          send(parent, {:provider_ready, self()})

          receive do
            :finish ->
              {:error,
               ProviderError.new(:denied, "mcp_input_required_refused", retryable?: false)}
          end
        end
      )

    {:ok, mission} = MissionEnvironment.new(capabilities: [blocked])

    dispatch =
      Task.async(fn ->
        Dispatcher.dispatch(
          state,
          :mission,
          mission,
          "blocked",
          %{},
          TestHelpers.dispatch_context(state, :mission, 2_000,
            lease: lease,
            mission_name: "default"
          ),
          nil,
          nil
        )
      end)

    assert_receive {:provider_ready, provider}
    send(evaluation_owner, :release)
    refute_receive {:evaluation_released, _status}, 50

    send(provider, :finish)

    assert %{status: :error, kind: :provider_error, reason: :denied} =
             Task.await(dispatch, 2_000)

    assert_receive {:evaluation_released,
                    {:ok,
                     %{
                       terminal_provider_failure?: true,
                       terminal_host_failure?: false
                     }}}

    assert {:ok, %{}, [], next_lease} = RunState.reserve_evaluation(state, "default", :fail_fast)

    assert {:ok,
            %{
              terminal_provider_failure?: false,
              terminal_host_failure?: false
            }} =
             RunState.release_evaluation_status(state, next_lease)
  end

  test "evaluation host-failure status is scoped to the exact active lease" do
    {:ok, state} = RunState.start(Limits.defaults())
    assert {:ok, %{}, [], lease} = RunState.reserve_evaluation(state, "default", :fail_fast)

    assert :ok = RunState.mark_evaluation_terminal_host_failure(state, make_ref())

    assert {:ok,
            %{
              terminal_provider_failure?: false,
              terminal_host_failure?: false
            }} = RunState.release_evaluation_status(state, lease)

    assert {:ok, %{}, [], next_lease} = RunState.reserve_evaluation(state, "default", :fail_fast)
    assert :ok = RunState.mark_evaluation_terminal_host_failure(state, next_lease)

    assert {:ok,
            %{
              terminal_provider_failure?: false,
              terminal_host_failure?: true
            }} = RunState.release_evaluation_status(state, next_lease)
  end

  test "continuation commit applies separate memory and exact-history ceilings atomically" do
    memory = %{"retained" => String.duplicate("m", 64)}
    history_value = String.duplicate("h", 64)
    memory_limit = RetainedSize.bytes(memory)
    history_limit = RetainedSize.bytes([history_value])

    {:ok, limits} =
      Limits.new(
        subordinate_evaluations: 4,
        evaluation_memory_bytes: memory_limit,
        evaluation_history_bytes: history_limit
      )

    {:ok, state} = RunState.start(limits)
    assert {:ok, %{}, [], first_lease} = RunState.reserve_evaluation(state, "default", :fail_fast)
    assert :ok = RunState.commit_evaluation(state, first_lease, memory, [])

    assert {:ok, ^memory, [], history_lease} =
             RunState.reserve_evaluation(state, "default", :fail_fast)

    assert :ok = RunState.commit_evaluation(state, history_lease, memory, [history_value])

    assert %{
             memory_bytes: ^memory_limit,
             history_bytes: ^history_limit,
             bytes: combined_bytes
           } = RunState.evaluation_memory_summary(state)

    assert combined_bytes > memory_limit

    assert {:ok, ^memory, [^history_value], rejected_lease} =
             RunState.reserve_evaluation(state, "default", :fail_fast)

    assert {:error, :history_exceeded} =
             RunState.commit_evaluation(
               state,
               rejected_lease,
               memory,
               [history_value, "overflow"]
             )

    assert {:ok, ^memory, [^history_value], release_lease} =
             RunState.reserve_evaluation(state, "default", :fail_fast)

    assert :ok = RunState.release_evaluation(state, release_lease)
  end

  test "continuation commit detaches retained values from transient binary parents" do
    parent = :binary.copy("x", 100_000)
    slice = binary_part(parent, 0, 1_000)

    {:ok, limits} =
      Limits.new(
        subordinate_evaluations: 2,
        evaluation_memory_bytes: 10_000,
        evaluation_history_bytes: 10_000
      )

    {:ok, state} = RunState.start(limits)
    assert {:ok, %{}, [], lease} = RunState.reserve_evaluation(state, "default", :fail_fast)
    assert :ok = RunState.commit_evaluation(state, lease, %{"slice" => slice}, [slice])

    assert {:ok, %{"slice" => retained}, [history], next_lease} =
             RunState.reserve_evaluation(state, "default", :fail_fast)

    assert :binary.referenced_byte_size(retained) == 1_000
    assert :binary.referenced_byte_size(history) == 1_000
    assert :ok = RunState.release_evaluation(state, next_lease)
  end

  test "dispatcher contains provider errors and rejects invalid returns" do
    missing_struct = Module.concat(__MODULE__, MissingProviderResult)

    assert {:ok, unavailable} =
             Capability.new(
               name: "unavailable",
               input_schema: @input_schema,
               callback: fn _ ->
                 {:error, ProviderError.new(:unavailable, "try later", retryable?: true)}
               end
             )

    assert {:ok, invalid} =
             Capability.new(
               name: "invalid",
               input_schema: @input_schema,
               callback: fn _ -> {:ok, self()} end
             )

    assert {:ok, malformed_struct} =
             Capability.new(
               name: "malformed-struct",
               input_schema: @input_schema,
               callback: fn _ -> {:ok, %{__struct__: missing_struct, value: <<1>>}} end
             )

    assert {:ok, environment} =
             WorkflowEnvironment.new(capabilities: [unavailable, invalid, malformed_struct])

    {:ok, state} = RunState.start(Limits.defaults())

    assert %{status: :error, kind: :provider_error, reason: :unavailable, retryable?: true} =
             Dispatcher.dispatch(
               state,
               :workflow,
               environment,
               "unavailable",
               %{},
               TestHelpers.dispatch_context(state, :workflow, 100),
               nil,
               nil
             )

    assert %{status: :error, kind: :result_exceeded, reason: :provider_result_limit} =
             Dispatcher.dispatch(
               state,
               :workflow,
               environment,
               "invalid",
               %{},
               TestHelpers.dispatch_context(state, :workflow, 100),
               nil,
               nil
             )

    assert %{status: :error, kind: :result_exceeded, reason: :provider_result_limit} =
             Dispatcher.dispatch(
               state,
               :workflow,
               environment,
               "malformed-struct",
               %{},
               TestHelpers.dispatch_context(state, :workflow, 100),
               nil,
               nil
             )
  end

  test "provider death before tracker attachment releases every reserved slot" do
    {:ok, capability} =
      Capability.new(
        name: "tiny-heap",
        input_schema: @input_schema,
        callback: fn _ -> {:ok, true} end
      )

    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])

    {:ok, limits} =
      Limits.new(
        live_provider_tasks: 1,
        workflow_capability_calls: 5,
        workflow_capability_calls_per_name: 5,
        provider_heap_words: 100
      )

    {:ok, state} = RunState.start(limits)

    for _attempt <- 1..4 do
      assert %{
               status: :error,
               kind: :provider_error,
               reason: :provider_exit,
               retryable?: false
             } =
               dispatch_after_provider_down(state, fn ->
                 Dispatcher.dispatch(
                   state,
                   :workflow,
                   environment,
                   "tiny-heap",
                   %{},
                   TestHelpers.dispatch_context(state, :workflow, 100),
                   nil,
                   nil
                 )
               end)
    end

    assert :ok = RunState.reserve_capability(state, :workflow, "tiny-heap")
    assert :ok = RunState.release_provider_slot(state)
  end

  test "write mission provider death before tracker attachment omits mutation state" do
    {:ok, capability} =
      Capability.new(
        name: "tiny-heap-write",
        input_schema: @input_schema,
        effect: :write,
        callback: fn _ -> {:ok, true} end
      )

    {:ok, environment} = MissionEnvironment.new(capabilities: [capability])
    {:ok, limits} = Limits.new(provider_heap_words: 100)
    {:ok, state} = RunState.start(limits)

    {:ok, _memory, _history, lease} =
      RunState.reserve_evaluation(state, "default", :fail_fast)

    assert %{
             status: :error,
             kind: :provider_error,
             reason: :provider_exit,
             retryable?: false
           } =
             result =
             dispatch_after_provider_down(state, fn ->
               Dispatcher.dispatch(
                 state,
                 :mission,
                 environment,
                 "tiny-heap-write",
                 %{},
                 TestHelpers.dispatch_context(
                   state,
                   :mission,
                   100,
                   lease: lease,
                   mission_name: "default"
                 ),
                 nil,
                 nil
               )
             end)

    refute Map.has_key?(result, :mutation_state)
  end

  test "provider attachment after run closure is rejected and releases its reservation" do
    {:ok, state} = RunState.start(Limits.defaults())
    assert :ok = RunState.reserve_capability(state, :workflow, "late-provider")
    assert :ok = RunState.close(state)

    provider =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    provider_ref = Process.monitor(provider)

    assert {:error, :closed} = RunState.attach_provider(state, provider)
    assert_receive {:DOWN, ^provider_ref, :process, ^provider, :killed}, 1_000

    internal = :sys.get_state(state.pid)
    assert internal.provider_tasks == 0
    assert internal.reservations == %{}
  end

  test "timed-out provider results cannot consume another callback slot after closure" do
    parent = self()

    {:ok, capability} =
      Capability.new(
        name: "slow",
        input_schema: @input_schema,
        callback: fn _ ->
          send(parent, :started)

          receive do
            :finish -> {:ok, %{"late" => true}}
          end
        end
      )

    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, limits} = Limits.new(live_provider_tasks: 1, run_duration_ms: 1_000)
    {:ok, state} = RunState.start(limits)

    # The budget only has to outlast the dispatch's own pre-provider work, not
    # the callback: it blocks until `:finish`, which never arrives. A 1 ms
    # request cannot do that. The validation worker is given the requested
    # budget minus the time already spent reaching it, so anything under a
    # millisecond of setup — a cold JSON-schema validator, a loaded CI
    # scheduler — collapses it to zero and reports the validator as
    # unavailable instead of the provider as timed out.
    assert %{status: :error, kind: :timeout, reason: :provider_timeout} =
             Dispatcher.dispatch(
               state,
               :workflow,
               environment,
               "slow",
               %{},
               TestHelpers.dispatch_context(state, :workflow, 100),
               nil,
               nil
             )

    assert_received :started
    assert :ok = RunState.close(state)

    assert %{status: :error, kind: :limit_exceeded, reason: :run_closed} =
             Dispatcher.dispatch(
               state,
               :workflow,
               environment,
               "slow",
               %{},
               TestHelpers.dispatch_context(state, :workflow, 100),
               nil,
               nil
             )
  end

  test "provider results are invalidated when the run closes during a callback" do
    parent = self()

    {:ok, capability} =
      Capability.new(
        name: "gate",
        input_schema: @input_schema,
        callback: fn _ ->
          send(parent, {:provider_started, self()})

          receive do
            :finish -> {:ok, %{"late" => true}}
          end
        end
      )

    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, state} = RunState.start(Limits.defaults())

    task =
      Task.async(fn ->
        Dispatcher.dispatch(
          state,
          :workflow,
          environment,
          "gate",
          %{},
          TestHelpers.dispatch_context(state, :workflow, 1_000),
          nil,
          nil
        )
      end)

    assert_receive {:provider_started, provider_pid}
    assert :ok = RunState.close(state)
    send(provider_pid, :finish)

    assert %{status: :error, kind: :limit_exceeded, reason: :run_closed} = Task.await(task)
  end

  test "closing with drain synchronously terminates attached providers" do
    {:ok, state} = RunState.start(Limits.defaults())
    assert :ok = RunState.reserve_capability(state, :workflow, "slow")

    provider =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    provider_ref = Process.monitor(provider)
    assert :ok = RunState.attach_provider(state, provider)
    assert :ok = RunState.close_and_drain(state)
    assert_receive {:DOWN, ^provider_ref, :process, ^provider, :killed}
    assert %{closed?: true} = RunState.usage(state)
  end

  # The tracker refuses an attachment exactly when it has stopped, which is what
  # it does once the owner goes down — so the release that follows the refusal
  # routinely races the owner's exit and must not kill the dispatcher.
  test "releasing a provider slot after the owner is gone reports closure" do
    {:ok, state} = RunState.start(Limits.defaults())
    assert :ok = RunState.reserve_capability(state, :workflow, "orphaned")

    owner_ref = Process.monitor(state.pid)
    assert :ok = RunState.stop(state)
    assert_receive {:DOWN, ^owner_ref, :process, _pid, _reason}

    assert {:error, :closed} = RunState.release_provider_slot(state)
  end

  # The tracker hears about owner death only through its monitor, so it can still
  # accept an attachment after the owner is gone. Pinning the owner pid to an
  # already-dead process reproduces that window without racing the monitor.
  # Everything a dispatch calls on a dead owner answers with the value that fails
  # closed for its own caller, so the dispatching process unwinds into a terminal
  # result instead of exiting. usage/1 and limits/1 are deliberately excluded:
  # there is no safe answer to invent, so they still exit.
  test "dispatch-path calls on a dead owner report instead of exiting" do
    {:ok, state} = RunState.start(Limits.defaults())

    owner_ref = Process.monitor(state.pid)
    assert :ok = RunState.stop(state)
    assert_receive {:DOWN, ^owner_ref, :process, _pid, _reason}

    assert {:error, :run_closed} = RunState.reserve_capability(state, :workflow, "gone")
    assert {:error, :run_closed} = RunState.finish_provider(state)
    assert {:error, :closed} = RunState.release_provider_slot(state)
    assert :ok = RunState.protocol_error(state)
    assert :ok = RunState.fail(state, :event_sink_error, :event_sink_error)
    assert :ok = RunState.mark_evaluation_terminal_provider_failure(state)

    assert catch_exit(RunState.usage(state))
    assert catch_exit(RunState.limits(state))
  end

  test "provider attachment reports closure when the owner died before the tracker noticed" do
    {:ok, state} = RunState.start(Limits.defaults())
    assert :ok = RunState.reserve_capability(state, :workflow, "orphaned")

    {dead_owner, dead_ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^dead_ref, :process, ^dead_owner, :normal}

    provider =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    provider_ref = Process.monitor(provider)

    assert {:error, :closed} = RunState.attach_provider(%{state | pid: dead_owner}, provider)
    assert_receive {:DOWN, ^provider_ref, :process, ^provider, :killed}

    assert :ok = RunState.close_and_drain(state)
  end

  test "provider attachment distinguishes a closed run from an already-dead provider" do
    {:ok, closed_state} = RunState.start(Limits.defaults())
    assert :ok = RunState.reserve_capability(closed_state, :workflow, "closed")
    assert :ok = RunState.close_and_drain(closed_state)

    live_provider =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    live_ref = Process.monitor(live_provider)

    assert {:error, :closed} = RunState.attach_provider(closed_state, live_provider)
    assert_receive {:DOWN, ^live_ref, :process, ^live_provider, :killed}

    {:ok, live_state} = RunState.start(Limits.defaults())
    assert :ok = RunState.reserve_capability(live_state, :workflow, "dead")
    {dead_provider, dead_ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^dead_ref, :process, ^dead_provider, :normal}

    assert {:error, :provider_down} = RunState.attach_provider(live_state, dead_provider)
    assert :ok = RunState.release_provider_slot(live_state)
  end

  test "a dispatching process killed mid-call releases its slot and stops its provider" do
    parent = self()

    {:ok, capability} =
      Capability.new(
        name: "slow",
        input_schema: @input_schema,
        callback: fn _ ->
          send(parent, {:provider_started, self()})

          receive do
            :finish -> {:ok, nil}
          end
        end
      )

    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, limits} = Limits.new(live_provider_tasks: 1)
    {:ok, state} = RunState.start(limits)

    caller =
      spawn(fn ->
        Dispatcher.dispatch(
          state,
          :workflow,
          environment,
          "slow",
          %{},
          TestHelpers.dispatch_context(state, :workflow, 30_000),
          nil,
          nil
        )
      end)

    assert_receive {:provider_started, provider}, 1_000
    provider_ref = Process.monitor(provider)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^provider_ref, :process, ^provider, :killed}, 1_000
    assert :ok = RunState.reserve_capability(state, :workflow, "slow")
  end

  test "run state shutdown kills providers attached to live reservations" do
    parent = self()

    {:ok, capability} =
      Capability.new(
        name: "slow",
        input_schema: @input_schema,
        callback: fn _ ->
          send(parent, {:provider_started, self()})

          receive do
            :finish -> {:ok, nil}
          end
        end
      )

    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])

    # The owner is also the dispatching process, so its death must not stop
    # run state before attached providers are reclaimed.
    owner =
      spawn(fn ->
        {:ok, state} = RunState.start(Limits.defaults())
        send(parent, {:state, state})

        Dispatcher.dispatch(
          state,
          :workflow,
          environment,
          "slow",
          %{},
          TestHelpers.dispatch_context(state, :workflow, 30_000),
          nil,
          nil
        )
      end)

    assert_receive {:state, state}, 1_000
    assert_receive {:provider_started, provider}, 1_000
    provider_ref = Process.monitor(provider)
    state_ref = Process.monitor(state.pid)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^state_ref, :process, _pid, _reason}, 1_000
    assert_receive {:DOWN, ^provider_ref, :process, ^provider, :killed}, 1_000
  end

  test "normal event sinks drop while private event sinks fail closed" do
    {:ok, limits} = Limits.new(normal_event_count: 1, normal_event_bytes: 10_000)

    {:ok, normal} =
      EventSink.start(:normal, limits,
        run_id: "normal",
        terminal_reserve: %{count: 0, bytes: 0}
      )

    {:ok, private} = EventSink.start(:private, limits, run_id: "private")

    assert :ok = EventSink.emit(normal, "run-started", %{"safe" => true})
    assert :ok = EventSink.emit(normal, "run-stopped", %{"safe" => true})
    assert %{"run-stopped" => 1} = EventSink.dropped(normal)

    assert :ok = EventSink.emit(private, "run-started", %{"safe" => true})
    assert {:error, :event_sink_error} = EventSink.emit(private, "run-stopped", %{"safe" => true})
  end

  test "stopped event sinks are contained according to their policy" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()

    {:ok, normal} = EventSink.start(:normal, limits, run_id: "stopped-normal")

    {:ok, normal_config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: normal
      )

    EventSink.stop(normal)

    assert {:error, %{kind: :event_sink_error, reason: :event_sink_error}} =
             Kernel.run("(return 42)", normal_config)

    {:ok, private} = EventSink.start(:private, limits, run_id: "stopped-private")

    {:ok, private_config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: private
      )

    EventSink.stop(private)

    assert {:error, %{kind: :event_sink_error, reason: :event_sink_error}} =
             Kernel.run("(return 42)", private_config)
  end

  test "private event sink exhaustion is a terminal event-sink error" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(normal_event_count: 1, normal_event_bytes: 10_000)
    {:ok, sink} = EventSink.start(:private, limits, run_id: "private-run")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:error, %{kind: :event_sink_error, reason: :event_sink_error}} =
             Kernel.run("(return 42)", config)
  end

  test "normal Runner finalization reserves and freezes the terminal envelope" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, limits} =
      Limits.new(
        normal_event_count: 4,
        normal_event_bytes: 100_000,
        event_payload_bytes: 10_000
      )

    {:ok, sink} = EventSink.start(:normal, limits, run_id: "normal-run")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{usage: %{events_dropped: dropped}}} = Kernel.run("(return 42)", config)
    assert dropped == %{"evaluation-stopped" => 1}

    events = EventSink.events(sink)

    assert Enum.map(events, & &1.type) ==
             ["run-started", "evaluation-started", "events-dropped", "run-stopped"]

    assert List.last(events).data.usage.events_dropped == dropped

    assert :ok = EventSink.emit(sink, "late-event", %{})
    assert EventSink.events(sink) == events
    assert EventSink.dropped(sink) == dropped
  end

  test "run configuration rejects a normal sink without terminal capacity" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, limits} =
      Limits.new(
        normal_event_count: 4,
        normal_event_bytes: 20_000,
        event_payload_bytes: 1_000
      )

    {:ok, sink} =
      EventSink.start(:normal, limits,
        run_id: "missing-terminal-reserve",
        terminal_reserve: %{count: 0, bytes: 0}
      )

    assert {:error, :invalid_run_config} =
             RunConfig.new(
               workflow_environment: workflow,
               missions: %{"default" => mission},
               input: %{},
               limits: limits,
               event_sink: sink
             )
  end

  test "run configuration rejects a provider session with different cleanup limits" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, session_limits} = Limits.new(provider_cleanup_timeout_ms: 100)
    {:ok, sink} = EventSink.start(:normal, limits)
    provider_session = ProviderSessionFixture.start([], session_limits)

    assert {:error, :invalid_run_config} =
             RunConfig.new(
               workflow_environment: workflow,
               missions: %{"default" => mission},
               input: %{},
               limits: limits,
               event_sink: sink,
               provider_session: provider_session
             )

    assert :ok = ProviderSession.close(provider_session)
    EventSink.stop(sink)
  end

  test "run configuration distinguishes generic and unbegun active provider sessions" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    generic_limits = %{limits | run_duration_ms: limits.run_duration_ms + 1}
    {:ok, generic_sink} = EventSink.start(:normal, limits)
    {:ok, active_sink} = EventSink.start(:normal, limits)
    {:ok, generic_session} = ProviderSession.start(generic_limits)
    {:ok, active_session} = ProviderSession.start_active(limits, "prepared-operation")

    assert {:ok, %{run_deadline: nil}} =
             RunConfig.new(
               workflow_environment: workflow,
               missions: %{"default" => mission},
               input: %{},
               limits: limits,
               event_sink: generic_sink,
               provider_session: generic_session
             )

    assert {:error, :invalid_run_config} =
             RunConfig.new(
               workflow_environment: workflow,
               missions: %{"default" => mission},
               input: %{},
               limits: limits,
               event_sink: active_sink,
               provider_session: active_session
             )

    assert :ok = ProviderSession.close(generic_session)
    assert :ok = ProviderSession.close(active_session)
    EventSink.stop(generic_sink)
    EventSink.stop(active_sink)
  end

  test "run configuration rejects a mutated result contract" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits)

    assert {:ok, contract} =
             ValueContract.compile(%{
               "type" => "object",
               "properties" => %{"result" => %{"type" => "integer"}}
             })

    forged =
      %{contract | schema: put_in(contract.schema, ["properties", "result", "type"], "string")}

    assert {:error, :invalid_run_config} =
             RunConfig.new(
               workflow_environment: workflow,
               missions: %{"default" => mission},
               input: %{},
               limits: limits,
               event_sink: sink,
               result_contract: forged
             )
  end

  test "tight terminal preflight covers cleanup-failure usage for Runner and REPL" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    build = fn payload_bytes, close ->
      {:ok, limits} =
        Limits.new(
          event_payload_bytes: payload_bytes,
          normal_event_count: 4,
          normal_event_bytes: 200_000
        )

      case EventSink.start(:normal, limits) do
        {:ok, sink} ->
          result =
            RunConfig.new(
              workflow_environment: workflow,
              missions: %{"default" => mission},
              input: %{},
              limits: limits,
              event_sink: sink,
              provider_session: ProviderSessionFixture.start([close], limits)
            )

          {result, sink, limits}

        {:error, :invalid_event_sink} ->
          {{:error, :invalid_event_sink}, nil, limits}
      end
    end

    fits? = fn payload_bytes ->
      case build.(payload_bytes, fn -> :ok end) do
        {{:ok, _config}, sink, _limits} ->
          EventSink.stop(sink)
          true

        {{:error, :invalid_run_config}, sink, _limits} ->
          EventSink.stop(sink)
          false

        {{:error, :invalid_event_sink}, nil, _limits} ->
          false
      end
    end

    search = fn search, low, high ->
      if low == high do
        low
      else
        middle = div(low + high, 2)

        if fits?.(middle),
          do: search.(search, low, middle),
          else: search.(search, middle + 1, high)
      end
    end

    minimum = search.(search, 1, 50_000)
    assert minimum > 1

    {{:ok, accepted}, accepted_sink, _limits} = build.(minimum, fn -> :ok end)
    EventSink.stop(accepted_sink)

    {{:error, :invalid_run_config}, too_tight_sink, _limits} =
      build.(minimum - 1, fn -> :ok end)

    assert EventSink.begin_capacity?(too_tight_sink, accepted.run_started_metadata)
    EventSink.stop(too_tight_sink)

    cleanup_failure = fn -> {:error, :fixture_cleanup_failed} end
    {{:ok, runner_config}, runner_sink, _limits} = build.(minimum, cleanup_failure)

    assert {:error,
            %PtcRunner.Kernel.Error{
              kind: :provider_cleanup_error,
              reason: :provider_cleanup_failed
            }} = Kernel.run("(return 42)", runner_config)

    assert List.last(EventSink.events(runner_sink)).data.reason == :provider_cleanup_failed

    {{:ok, repl_config}, _repl_sink, _limits} = build.(minimum, cleanup_failure)
    {:ok, repl} = ReplSession.new(config: repl_config)

    assert {:error, :provider_cleanup_failed, events} = ReplSession.close(repl)
    assert List.last(events).data.reason == :provider_cleanup_failed

    {{:ok, abort_config}, _abort_sink, _limits} = build.(minimum, fn -> :ok end)
    {:ok, abort_repl} = ReplSession.new(config: abort_config)

    long_reason =
      :frontend_exception_with_a_longer_terminal_reason_than_provider_cleanup_failed

    assert {:ok, abort_events} = ReplSession.abort(abort_repl, long_reason)
    assert List.last(abort_events).data.reason == long_reason
  end

  test "terminal preflight covers the protocol error that crosses its ceiling" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    build = fn payload_bytes ->
      {:ok, limits} =
        Limits.new(
          protocol_errors: 9,
          event_payload_bytes: payload_bytes,
          normal_event_count: 4,
          normal_event_bytes: 100_000
        )

      case EventSink.start(:normal, limits) do
        {:ok, sink} ->
          result =
            RunConfig.new(
              workflow_environment: workflow,
              missions: %{"default" => mission},
              input: %{},
              limits: limits,
              event_sink: sink
            )

          {result, sink, limits}

        {:error, :invalid_event_sink} ->
          {{:error, :invalid_event_sink}, nil, limits}
      end
    end

    minimum =
      Enum.find(1..50_000, fn payload_bytes ->
        case build.(payload_bytes) do
          {{:ok, _config}, sink, _limits} ->
            EventSink.stop(sink)
            true

          {{:error, _reason}, sink, _limits} ->
            if sink, do: EventSink.stop(sink)
            false
        end
      end)

    {{:ok, config}, sink, limits} = build.(minimum)
    assert :ok = EventSink.claim(sink, config.claim_id, config.run_started_metadata)
    {:ok, state} = RunState.start(limits)

    Enum.each(1..limits.protocol_errors, fn _ ->
      assert :ok = RunState.protocol_error(state)
    end)

    assert {:error, :protocol_error_limit} = RunState.protocol_error(state)
    usage = RunState.usage(state)
    assert usage.protocol_errors == limits.protocol_errors + 1

    assert {:ok, %{events: events}} =
             EventSink.finalize_and_events(sink, %{
               outcome: :error,
               reason: :protocol_errors,
               usage: usage
             })

    assert List.last(events).type == "run-stopped"
    RunState.stop(state)
    EventSink.stop(sink)
  end

  test "capability construction detaches names from transient binary parents" do
    parent = "s" <> String.duplicate("x", 500_000)
    retained_name = binary_part(parent, 0, 65)
    assert :binary.referenced_byte_size(retained_name) > byte_size(retained_name)

    {:ok, retained} =
      Capability.new(
        name: retained_name,
        input_schema: @input_schema,
        callback: fn _ -> {:ok, nil} end
      )

    assert :binary.referenced_byte_size(retained.name) == byte_size(retained.name)

    {:ok, logical_long} =
      Capability.new(
        name: String.duplicate("l", 128),
        input_schema: @input_schema,
        callback: fn _ -> {:ok, nil} end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [retained, logical_long])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(workflow_capability_calls: 1)
    {:ok, sink} = EventSink.start(:normal, limits)

    assert {:ok, _config} =
             RunConfig.new(
               workflow_environment: workflow,
               missions: %{"default" => mission},
               input: %{},
               limits: limits,
               event_sink: sink
             )
  end

  test "terminal preflight counts only metered environment capabilities" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, limits} =
      Limits.new(
        event_payload_bytes: 7_000,
        normal_event_count: 4,
        normal_event_bytes: 100_000
      )

    {:ok, sink} = EventSink.start(:normal, limits)

    assert {:ok, _config} =
             RunConfig.new(
               workflow_environment: workflow,
               missions: %{"default" => mission},
               input: %{},
               limits: limits,
               event_sink: sink
             )

    EventSink.stop(sink)
  end

  test "run configuration requires exact sink limits and room for run-started" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    sink_limits = Limits.defaults()
    {:ok, normal} = EventSink.start(:normal, sink_limits, run_id: "mismatched-normal")
    {:ok, private} = EventSink.start(:private, sink_limits, run_id: "mismatched-private")
    config_limits = %{sink_limits | run_duration_ms: sink_limits.run_duration_ms + 1}

    for sink <- [normal, private] do
      assert {:error, :invalid_run_config} =
               RunConfig.new(
                 workflow_environment: workflow,
                 missions: %{"default" => mission},
                 input: %{},
                 limits: config_limits,
                 event_sink: sink
               )
    end

    {:ok, base_limits} = Limits.new(normal_event_count: 3, event_payload_bytes: 5_000)
    reserve = EventSink.terminal_reserve(:normal, base_limits)

    {:ok, tight_limits} =
      Limits.new(
        normal_event_count: 3,
        normal_event_bytes: reserve.bytes + 1,
        event_payload_bytes: 5_000
      )

    {:ok, tight} = EventSink.start(:normal, tight_limits, run_id: "tight-run-started")

    assert {:error, :invalid_run_config} =
             RunConfig.new(
               workflow_environment: workflow,
               missions: %{"default" => mission},
               input: %{},
               limits: tight_limits,
               event_sink: tight
             )
  end

  test "a finalized run configuration is one-shot" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "one-shot-config")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: 42}} = Kernel.run("(return 42)", config)

    assert {:error, %{kind: :event_sink_error, reason: :event_sink_error}} =
             Kernel.run("(return 43)", config)
  end

  test "a shared run configuration is claimed atomically before execution" do
    parent = self()

    {:ok, blocking} =
      Capability.new(
        name: "blocking",
        input_schema: @input_schema,
        callback: fn _arguments ->
          send(parent, {:provider_started, self()})

          receive do
            :continue -> {:ok, 42}
          end
        end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [blocking])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "atomic-run-claim")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink,
        provider_session:
          ProviderSessionFixture.start(
            [
              fn ->
                send(parent, :resource_closed)
                :ok
              end
            ],
            limits
          )
      )

    first = Task.async(fn -> Kernel.run("(return (tool/blocking {}))", config) end)
    assert_receive {:provider_started, provider}

    assert {:error, %{kind: :event_sink_error, reason: :event_sink_error}} =
             Kernel.run("(return 43)", config)

    refute_receive :resource_closed

    send(provider, :continue)
    assert {:ok, %{value: %{"status" => "ok", "value" => 42}}} = Task.await(first)
    assert_receive :resource_closed

    assert Enum.count(EventSink.events(sink), &(&1.type == "run-started")) == 1
  end

  test "a distinct config losing a concurrent sink claim closes only its resources" do
    parent = self()

    {:ok, blocking} =
      Capability.new(
        name: "distinct-claim",
        input_schema: @input_schema,
        callback: fn _arguments ->
          send(parent, {:distinct_claim_started, self()})

          receive do
            :continue -> {:ok, 42}
          end
        end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [blocking])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "distinct-run-claim")

    config = fn close_message ->
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink,
        provider_session:
          ProviderSessionFixture.start(
            [
              fn ->
                send(parent, close_message)
                :ok
              end
            ],
            limits
          )
      )
    end

    {:ok, winner_config} = config.(:winner_resource_closed)
    {:ok, loser_config} = config.(:loser_resource_closed)

    winner =
      Task.async(fn ->
        Kernel.run("(return (tool/distinct-claim {}))", winner_config)
      end)

    assert_receive {:distinct_claim_started, provider}

    assert {:error, %{kind: :event_sink_error, reason: :event_sink_error}} =
             Kernel.run("(return 43)", loser_config)

    assert_receive :loser_resource_closed
    refute_receive :winner_resource_closed

    send(provider, :continue)
    assert {:ok, %{value: %{"status" => "ok", "value" => 42}}} = Task.await(winner)
    assert_receive :winner_resource_closed
  end

  test "run owners provide explicit teardown and stop with their creating process" do
    {:ok, state} = RunState.start(Limits.defaults())
    state_ref = Process.monitor(state.pid)
    assert :ok = RunState.stop(state)
    assert_receive {:DOWN, ^state_ref, :process, _, :normal}

    parent = self()

    owner =
      spawn(fn ->
        {:ok, sink} = EventSink.start(:normal, Limits.defaults())
        send(parent, {:owned_sink, sink})
      end)

    owner_ref = Process.monitor(owner)
    assert_receive {:owned_sink, sink}
    sink_ref = Process.monitor(sink.pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:DOWN, ^sink_ref, :process, _, sink_reason}
    assert sink_reason in [:normal, :noproc]
  end

  test "component bundles use component IDs for deterministic dependency ordering" do
    {:ok, first} = Component.new(id: "first", source: "(ns first) (defn value [] 1)")

    {:ok, second} =
      Component.new(
        id: "second",
        source: "(ns second) (defn value [] 2)",
        dependencies: ["first"]
      )

    assert {:ok,
            %{component_ids: ["first", "second"], components: [first_component, second_component]}} =
             Kernel.compile_bundle([second, first])

    assert first_component.id == "first"
    assert second_component.id == "second"

    assert {:error, %{reason: :missing_component_dependency}} =
             Kernel.compile_bundle([%{first | dependencies: ["missing"]}])

    assert {:error, %{reason: :component_cycle}} =
             Kernel.compile_bundle([%{first | dependencies: ["second"]}, second])
  end

  test "bundle compilation confines large artifacts with independent heap and artifact limits" do
    payload = String.duplicate("x", 1_500_000)

    {:ok, component} =
      Component.new(id: "large", source: ~s|(ns large) (def value "#{payload}")|)

    assert {:error, %{reason: reason}} = Kernel.compile_bundle([component])
    assert reason in [:bundle_compile_heap_exceeded, :bundle_artifact_exceeded]
  end

  test "component dependencies make dependency namespaces visible" do
    {:ok, base} =
      Component.new(id: "base", source: "(ns base \"Base helpers.\") (defn value [] 40)")

    {:ok, consumer} =
      Component.new(
        id: "consumer",
        source: "(ns consumer \"Consumer helpers.\") (defn answer [] (+ (base/value) 2))",
        dependencies: ["base"]
      )

    assert {:ok, bundle} = Kernel.compile_bundle([consumer, base])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "component-dependencies")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: 42}} = Kernel.run("(return (consumer/answer))", config)
  end

  test "each bundle component is validated before aggregate compilation" do
    {:ok, first} = Component.new(id: "first", source: "(ns first) (defn value [] 1)")

    {:ok, malformed} =
      Component.new(
        id: "malformed",
        source: "(defn escaped [] 42) (ns malformed) (defn value [] 2)",
        dependencies: ["first"]
      )

    assert {:error, %{reason: :component_compile_error, id: "malformed"}} =
             Kernel.compile_bundle([first, malformed])
  end

  test "span attribution metadata cannot displace a large compile diagnostic" do
    signature = String.duplicate("x", 70_000)

    {:ok, component} =
      Component.new(
        id: "invalid-signature",
        source: ~s|(ns invalid-signature) (defn bad {:signature "#{signature}"} [] 1)|
      )

    assert {:error, %{reason: :component_compile_error, id: "invalid-signature"}} =
             Kernel.compile_bundle([component])
  end

  test "an oversized ref locator cannot displace a compile diagnostic" do
    symbol = "f" <> String.duplicate("x", 70_000)

    {:ok, component} =
      Component.new(
        id: "duplicate-long-ref",
        source: "(ns duplicate-long-ref) (defn #{symbol} [] 1) (defn #{symbol} [] 2)"
      )

    assert {:error, %{reason: :component_compile_error, id: "duplicate-long-ref"}} =
             Kernel.compile_bundle([component])
  end

  test "bundle compilation returns diagnostics for malformed component terms" do
    assert {:error, %{reason: :invalid_components}} = Kernel.compile_bundle([%{}])

    {:ok, component} = Component.new(id: "valid", source: "(ns valid) (def value 1)")

    assert {:error, %{reason: :invalid_components}} =
             Kernel.compile_bundle([%{component | source: :forged}])

    assert {:error, %{reason: :invalid_components}} =
             Kernel.compile_bundle([%{component | dependencies: :forged}])

    assert {:error, %{reason: :bundle_limit_exceeded}} =
             Kernel.compile_bundle([
               %{component | dependencies: List.duplicate("valid", 100_000)}
             ])
  end

  test "new Kernel run executes a bounded workflow through explicit configuration" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "workflow")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: 42, evaluation_memory: %{defined_count: 0}}} =
             Kernel.run("(return (+ 40 2))", config)

    events = EventSink.events(sink)

    assert ["run-started", "evaluation-started", "evaluation-stopped", "run-stopped"] ==
             Enum.map(events, & &1.type)

    expected_hash =
      "sha256:" <> Base.encode16(:crypto.hash(:sha256, "42"), case: :lower)

    assert List.last(events).data.result_hash == expected_hash
  end

  test "workflow timeout diagnostics name the effective configured limit" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(workflow_timeout_ms: 1, run_duration_ms: 1_000)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "workflow-timeout")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:error, error} = Kernel.run("(reduce + (range 1000000))", config)
    assert error.kind == :limit_exceeded
    assert error.reason in [:timeout, :compile_timeout]
    assert error.details.limit == :workflow_timeout_ms
    assert error.details.limit_ms == 1
    assert error.details.phase in [:compilation, :execution]
    assert error.details.message =~ "workflow_timeout_ms exceeded during"
  end

  test "Kernel JSON boundaries reject Java callable authority before commit" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "java-projection")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:error, %{kind: :workflow_failed, reason: :java_projection_error}} =
             Kernel.run("(return Boolean/parseBoolean)", config)

    {:ok, state} = RunState.start(limits)

    assert %{
             outcome: :evaluation_error,
             kind: :java_projection_error
           } =
             Evaluation.evaluate_source(
               state,
               "default",
               mission,
               "(do (def parser Boolean/parseBoolean) parser)",
               100
             )

    assert %{defined_count: 0, history_count: 0} = RunState.evaluation_memory_summary(state)
  end

  test "failed subordinate evaluation start retains no unattempted inspection source" do
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(normal_event_count: 1, normal_event_bytes: 20_000)
    {:ok, state} = RunState.start(limits)
    {:ok, event_sink} = EventSink.start(:private, limits, run_id: "full-before-evaluation")

    {:ok, inspection_sink} =
      InspectionSink.start(run_id: "full-before-evaluation", trace_id: "full-before-evaluation")

    assert :ok = EventSink.emit(event_sink, "occupied", %{})

    assert %{outcome: :evaluation_error, reason: :event_sink_error} =
             Evaluation.evaluate_source(
               state,
               "default",
               mission,
               "(return 42)",
               100,
               event_sink,
               inspection_sink
             )

    assert {:ok, []} = InspectionSink.records(inspection_sink)
    assert :ok = InspectionSink.stop(inspection_sink)
    assert :ok = EventSink.stop(event_sink)
    assert :ok = RunState.stop(state)
  end

  test "Kernel rejects public projection collisions instead of losing entries" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()

    expressions = [
      ~S|{(fn [x] x) 1 (fn [x] (+ x 1)) 2}|,
      ~S|#{(fn [x] x) (fn [x] (+ x 1))}|,
      ~S|{(fn [x] x) 1 "#fn[...]" 2}|,
      ~S|#{(fn [x] x) "#fn[...]"}|
    ]

    for {expression, index} <- Enum.with_index(expressions) do
      {:ok, sink} = EventSink.start(:normal, limits, run_id: "projection-collision-#{index}")

      {:ok, config} =
        RunConfig.new(
          workflow_environment: workflow,
          missions: %{"default" => mission},
          input: %{},
          limits: limits,
          event_sink: sink
        )

      assert {:error,
              %{
                kind: :workflow_failed,
                reason: :public_projection_collision,
                details: %{projection_error: projection_error}
              }} = Kernel.run("(return #{expression})", config)

      assert projection_error =~ "public_projection_collision"
    end

    for expression <- expressions do
      {:ok, state} = RunState.start(limits)

      assert %{
               outcome: :evaluation_error,
               kind: :public_projection_collision,
               continuation_effect: :preserved,
               retryable?: false
             } =
               Evaluation.evaluate_source(state, "default", mission, expression, 100, nil, nil)

      assert %{defined_count: 0, history_count: 0} =
               RunState.evaluation_memory_summary(state)
    end
  end

  test "Kernel classifies Lisp and Java projector failures at both exit paths" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, limits} = Limits.new()

    malformed_values = [
      {{:symbol_ref, <<255>>}, :invalid_symbol_ref},
      {%PtcRunner.Lisp.Keyword{name: "invalid/name"}, :invalid_keyword},
      {[1 | 2], :java_projection_error},
      {%{__struct__: PtcRunner.MissingJavaProjectionStruct, payload: 1}, :java_projection_error}
    ]

    for {malformed, expected_kind} <- malformed_values do
      {:ok, sink} = EventSink.start(:normal, limits, run_id: "malformed-#{expected_kind}")
      {:ok, mission} = MissionEnvironment.new([])
      mission = %{mission | data: %{"bad" => malformed}}

      {:ok, config} =
        RunConfig.new(
          workflow_environment: workflow,
          missions: %{"default" => mission},
          input: %{},
          limits: limits,
          event_sink: sink
        )

      config = %{config | input: %{"bad" => malformed}}

      assert {:error, %{kind: :workflow_failed, reason: ^expected_kind}} =
               Kernel.run("(return data/bad)", config)

      {:ok, state} = RunState.start(limits)

      assert %{
               outcome: :evaluation_error,
               kind: ^expected_kind,
               continuation_effect: :preserved,
               retryable?: false
             } =
               Evaluation.evaluate_source(state, "default", mission, "data/bad", 100, nil, nil)

      assert %{defined_count: 0, history_count: 0} =
               RunState.evaluation_memory_summary(state)
    end
  end

  test "Kernel safely projects quoted symbols and rejects equivalent string-key collisions" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()

    {:ok, sink} = EventSink.start(:normal, limits, run_id: "quoted-symbol-key")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: %{%Format.SymbolRef{name: "foo"} => 1}}} =
             Kernel.run(~S|(return {'foo 1})|, config)

    assert %{data: %{result_hash: "sha256:" <> hash}} = List.last(EventSink.events(sink))
    assert byte_size(hash) == 64

    {:ok, sink} = EventSink.start(:normal, limits, run_id: "quoted-symbol-key-collision")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:error, %{kind: :workflow_failed, reason: :public_projection_collision}} =
             Kernel.run(~S|(return {'foo 1 "'foo" 2})|, config)
  end

  test "explicit workflow failure returns the outer error algebra" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "workflow-fail")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    private = "PRIVATE_GENERATED_SOURCE_(return_42)"

    assert {:error, %{kind: :workflow_failed, reason: :explicit_failure} = error} =
             Kernel.run(~s|(fail "#{private}")|, config)

    refute inspect(error) =~ private
  end

  test "private workflow evaluator failures expose only fixed diagnostics" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:private, limits, run_id: "private-workflow-error")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    secret = "PRIVATE_NOT_CALLABLE_VALUE"

    assert {:error,
            %{
              kind: :workflow_failed,
              details: %{message: "private workflow failed"}
            } = error} = Kernel.run(~s|("#{secret}" 1)|, config)

    refute inspect(error) =~ secret
  end

  test "explicit workflow failure exposes only bounded safe taxonomy" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "workflow-failure-taxonomy")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    secret = "PRIVATE_FAILURE_DETAIL"

    assert {:error,
            %{
              reason: :explicit_failure,
              details: %{failure_kind: "turn-limit"}
            }} =
             Kernel.run(~s|(fail {:kind :turn-limit :reason "#{secret}"})|, config)

    stopped = List.last(EventSink.events(sink))
    assert stopped.type == "run-stopped"
    assert stopped.data.failure_kind == "turn-limit"
    refute inspect(stopped) =~ secret
  end

  test "application-defined failure kinds are fingerprinted" do
    taxonomy =
      SafeMetadata.failure_taxonomy(%{
        "kind" => "PRIVATE_CUSTOM_FAILURE",
        "detail" => "PRIVATE_DETAIL"
      })

    assert %{failure_kind_fingerprint: "sha256:" <> digest} = taxonomy
    assert byte_size(digest) == 64
    refute inspect(taxonomy) =~ "PRIVATE"
  end

  test "parallel fail retains only bounded safe taxonomy" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    secret = "PRIVATE_PARALLEL_FAILURE_DETAIL"

    cases = [
      {:pcalls, :pcalls_error,
       ~s|(pcalls #(fail {:kind :evaluation-unavailable :reason "#{secret}"}))|},
      {:pmap, :pmap_error,
       ~s|(pmap (fn [_] (fail {:kind :evaluation-unavailable :reason "#{secret}"})) [1])|},
      {:nested, :pcalls_error,
       ~s|(pcalls #(pmap (fn [_] (fail {:kind :evaluation-unavailable :reason "#{secret}"})) [1]))|},
      {:ordinary_hof, :pcalls_error,
       ~s|(map (fn [_] (pcalls #(fail {:kind :evaluation-unavailable :reason "#{secret}"}))) [1])|}
    ]

    Enum.each(cases, fn {name, reason, source} ->
      {:ok, sink} =
        EventSink.start(:normal, limits, run_id: "parallel-failure-taxonomy-#{name}")

      {:ok, config} =
        RunConfig.new(
          workflow_environment: workflow,
          missions: %{"default" => mission},
          input: %{},
          limits: limits,
          event_sink: sink
        )

      assert {:error,
              %{
                reason: ^reason,
                details: %{failure_kind: "evaluation-unavailable"}
              } = error} = Kernel.run(source, config)

      assert %{type: "run-stopped", data: %{failure_kind: "evaluation-unavailable"}} =
               List.last(EventSink.events(sink))

      refute inspect(error) =~ secret
      refute EventSink.events(sink) |> inspect() |> String.contains?(secret)
    end)
  end

  test "parallel non-fail controls do not publish failure taxonomy" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "parallel-return-control")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:error, %{reason: :pcalls_error, details: details}} =
             Kernel.run(~S|(pcalls #(return {:kind :assertion-failed}))|, config)

    refute Map.has_key?(details, :failure_kind)
    refute Map.has_key?(details, :failure_kind_fingerprint)
  end

  test "new Kernel workflow routes only granted capabilities through the dispatcher" do
    {:ok, add} =
      Capability.new(
        name: "add",
        input_schema: @input_schema,
        callback: fn %{"left" => left, "right" => right} -> {:ok, %{"sum" => left + right}} end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [add])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "capability")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: %{"status" => "ok", "value" => %{"sum" => 42}}}} =
             Kernel.run("(return (tool/add {:left 40 :right 2}))", config)

    assert [started, stopped] =
             sink
             |> EventSink.events()
             |> Enum.filter(&(&1.type in ["capability-started", "capability-stopped"]))

    assert %{data: %{environment: :workflow, name: "add"}} = started
    assert %{data: %{environment: :workflow, name: "add", status: :ok}} = stopped
  end

  test "ambiguous normalized capability arguments are rejected before provider dispatch" do
    parent = self()

    {:ok, capability} =
      Capability.new(
        name: "capture",
        input_schema: @input_schema,
        callback: fn arguments ->
          send(parent, {:provider_called, arguments})
          {:ok, true}
        end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "ambiguous-arguments")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok,
            %{
              value: %{
                "status" => "error",
                "kind" => "protocol_error",
                "reason" => "ambiguous_arguments"
              }
            }} =
             Kernel.run(
               ~S|(return (tool/capture {"outer" {"path" "a" :path "b"}}))|,
               config
             )

    refute_receive {:provider_called, _arguments}
  end

  test "mission ambiguity is a counted protocol error before provider dispatch" do
    parent = self()

    {:ok, capability} =
      Capability.new(
        name: "capture",
        input_schema: @input_schema,
        callback: fn arguments ->
          send(parent, {:mission_provider_called, arguments})
          {:ok, true}
        end
      )

    {:ok, mission} = MissionEnvironment.new(capabilities: [capability])
    {:ok, state} = RunState.start(Limits.defaults())

    assert %{
             outcome: :returned,
             value: %{"kind" => "protocol_error", "reason" => "ambiguous_arguments"}
           } =
             Evaluation.evaluate_source(
               state,
               "default",
               mission,
               ~S|(return (tool/capture {"path" "a" :path "b"}))|,
               100
             )

    assert %{protocol_errors: 1} = RunState.usage(state)
    refute_receive {:mission_provider_called, _arguments}
  end

  # A resource kill says the query was too big, not that the world changed.
  # Refusing to retry after a read-only page fetch spends the agent's remaining
  # turns protecting state nothing mutated, which is what ended a real
  # investigation at the point it should have narrowed and continued.
  test "a resource kill stays retryable after read-only capability activity" do
    {:ok, reader} =
      Capability.new(
        name: "page",
        input_schema: @input_schema,
        effect: :read,
        callback: fn _ -> {:ok, %{"items" => Enum.to_list(1..64)}} end
      )

    {:ok, mission} = MissionEnvironment.new(capabilities: [reader])
    {:ok, limits} = Limits.new(%{evaluation_heap_words: 200_000})
    {:ok, state} = RunState.start(limits)

    assert %{outcome: :evaluation_error, retryable?: true} =
             Evaluation.evaluate_source(
               state,
               "default",
               mission,
               ~S|(do (tool/page {}) (reduce (fn [acc i] (conj acc (range 0 4096))) [] (range 0 4096)))|,
               5_000
             )
  end

  test "parallel capacity stays retryable after read-only capability activity" do
    {:ok, reader} =
      Capability.new(
        name: "page",
        input_schema: @input_schema,
        effect: :read,
        callback: fn _ -> {:ok, %{"items" => [1, 2, 3]}} end
      )

    {:ok, mission} = MissionEnvironment.new(capabilities: [reader])
    {:ok, state} = RunState.start(Limits.defaults())

    assert %{
             outcome: :evaluation_error,
             kind: :parallel_capacity_exceeded,
             retryable?: true
           } =
             Evaluation.evaluate_source(
               state,
               "default",
               mission,
               ~S|(do (tool/page {}) (pmap (fn [_] (pmap inc [1 2])) (range 0 16)))|,
               5_000
             )
  end

  test "a resource kill is not retryable after write or undeclared capability activity" do
    for effect <- [:write, :unknown] do
      {:ok, capability} =
        Capability.new(
          name: "commit",
          input_schema: @input_schema,
          effect: effect,
          callback: fn _ -> {:ok, %{"ok" => true}} end
        )

      {:ok, mission} = MissionEnvironment.new(capabilities: [capability])
      {:ok, limits} = Limits.new(%{evaluation_heap_words: 200_000})
      {:ok, state} = RunState.start(limits)

      assert %{outcome: :evaluation_error, retryable?: false} =
               Evaluation.evaluate_source(
                 state,
                 "default",
                 mission,
                 ~S|(do (tool/commit {}) (reduce (fn [acc i] (conj acc (range 0 4096))) [] (range 0 4096)))|,
                 5_000
               ),
             "effect #{inspect(effect)} must keep a resource kill terminal"
    end
  end

  test "an explicit capability failure reports whether correcting it is effect-safe" do
    for {effect, retryable?} <- [read: true, write: false, unknown: false] do
      {:ok, capability} =
        Capability.new(
          name: "lookup",
          input_schema: @input_schema,
          effect: effect,
          callback: fn _ ->
            {:error, ProviderError.new(:not_found, "not in the frozen source")}
          end
        )

      {:ok, mission} = MissionEnvironment.new(capabilities: [capability])
      {:ok, state} = RunState.start(Limits.defaults())

      assert %{
               outcome: :failed,
               capability_activity?: true,
               capability_failure?: true,
               retryable?: ^retryable?,
               value: %{
                 "status" => "error",
                 "kind" => "provider_error",
                 "reason" => "not_found"
               }
             } =
               Evaluation.evaluate_source(
                 state,
                 "default",
                 mission,
                 ~S|(fail (tool/lookup {}))|,
                 5_000
               )

      if effect == :read do
        {:ok, copied_state} = RunState.start(Limits.defaults())

        assert %{
                 outcome: :failed,
                 capability_activity?: true,
                 capability_failure?: false,
                 retryable?: true
               } =
                 Evaluation.evaluate_source(
                   copied_state,
                   "default",
                   mission,
                   ~S|(let [response (tool/lookup {}) copied (into {} response)] (fail copied))|,
                   5_000
                 )
      end
    end

    {:ok, lookup} =
      Capability.new(
        name: "lookup",
        input_schema: @input_schema,
        effect: :read,
        callback: fn _ -> {:error, ProviderError.new(:not_found, "not found")} end
      )

    {:ok, cap_component} = Library.component("cap")
    {:ok, cap_bundle} = Kernel.compile_bundle([cap_component])
    {:ok, cap_mission} = MissionEnvironment.new(bundle: cap_bundle, capabilities: [lookup])
    {:ok, cap_state} = RunState.start(Limits.defaults())

    assert %{outcome: :failed, capability_failure?: true, retryable?: true} =
             Evaluation.evaluate_source(
               cap_state,
               "default",
               cap_mission,
               ~S|(cap/unwrap! (tool/lookup {}))|,
               5_000
             )

    {:ok, bound_cap_state} = RunState.start(Limits.defaults())

    assert %{outcome: :failed, capability_failure?: true, retryable?: true} =
             Evaluation.evaluate_source(
               bound_cap_state,
               "default",
               cap_mission,
               ~S|(let [response (tool/lookup {})] (cap/unwrap! response))|,
               5_000
             )

    {:ok, facade_component} =
      Component.new(
        id: "facade",
        dependencies: ["cap"],
        source: """
        (ns facade)

        (defn- unwrap-through [envelope]
          (cap/unwrap! envelope))

        (defn- forward-through [envelope]
          (unwrap-through envelope))

        (defn lookup []
          (forward-through (tool/lookup {})))

        (defn copied-lookup []
          (forward-through (into {} (tool/lookup {}))))
        """
      )

    {:ok, facade_bundle} = Kernel.compile_bundle([cap_component, facade_component])

    {:ok, facade_mission} =
      MissionEnvironment.new(bundle: facade_bundle, capabilities: [lookup])

    {:ok, facade_state} = RunState.start(Limits.defaults())

    assert %{outcome: :failed, capability_failure?: true, retryable?: true} =
             Evaluation.evaluate_source(
               facade_state,
               "default",
               facade_mission,
               ~S|(facade/lookup)|,
               5_000
             )

    {:ok, copied_facade_state} = RunState.start(Limits.defaults())

    assert %{outcome: :failed, capability_failure?: false, retryable?: true} =
             Evaluation.evaluate_source(
               copied_facade_state,
               "default",
               facade_mission,
               ~S|(facade/copied-lookup)|,
               5_000
             )

    {:ok, copied_cap_state} = RunState.start(Limits.defaults())

    assert %{outcome: :failed, capability_failure?: false, retryable?: true} =
             Evaluation.evaluate_source(
               copied_cap_state,
               "default",
               cap_mission,
               ~S|(let [response (tool/lookup {}) copied (into {} response)] (cap/unwrap! copied))|,
               5_000
             )

    {:ok, mission} = MissionEnvironment.new([])
    {:ok, state} = RunState.start(Limits.defaults())

    assert %{
             outcome: :failed,
             capability_activity?: false,
             capability_failure?: false,
             retryable?: true
           } =
             Evaluation.evaluate_source(
               state,
               "default",
               mission,
               ~S|(fail {:status :error :kind :provider-error :reason :not-found})|,
               5_000
             )
  end

  # `Kernel.run` legitimately answers Elixir terms: `tool/kernel-eval` returns an
  # atom-keyed envelope and embedding hosts read it, so the JSON requirement
  # belongs to the artifact rather than to the boundary. What was wrong was the
  # report — an unwritable value looked like a filesystem failure.
  test "an unencodable result artifact names the value, not the write" do
    dir = Path.join(System.tmp_dir!(), "ptc-unencodable-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "result.json")

    assert {:error, {:result_not_json_encodable, :object}} =
             ResultArtifact.persist(path, %{outcome: :returned, value: 1}, :normal, :normal)

    refute File.exists?(path)

    assert :ok = ResultArtifact.persist(path, %{"outcome" => "returned"}, :normal, :normal)
    assert File.exists?(path)
  end

  test "mission evaluation is serialized, persistent, and cannot use workflow capabilities" do
    {:ok, workflow_capability} =
      Capability.new(
        name: "workflow-only",
        input_schema: @input_schema,
        callback: fn _ -> {:ok, %{"ok" => true}} end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [workflow_capability])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, state} = RunState.start(limits)

    assert %{outcome: :continued} =
             Evaluation.evaluate_source(state, "default", mission, "(def x 40)", 100)

    assert %{outcome: :returned, value: 42} =
             Evaluation.evaluate_source(state, "default", mission, "(return (+ x 2))", 100)

    assert %{outcome: :evaluation_error} =
             Evaluation.evaluate_source(state, "default", mission, "(tool/workflow-only {})", 100)

    assert %{capability_calls: %{workflow: %{}, mission: %{}}} = RunState.usage(state)
    assert workflow.capabilities["workflow-only"]
  end

  test "subordinate and workflow terminal values project closures without executable state" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, state} = RunState.start(limits)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "closure-projection")

    assert %{outcome: :continued, value: %Format.Fn{params: "..."}, prints: []} =
             Evaluation.evaluate_source(
               state,
               "default",
               mission,
               ~S|(let [secret "sentinel-projection-secret"] (fn [named-parameter] secret))|,
               100
             )

    assert %{outcome: :failed, value: %Format.Fn{params: "..."}} =
             Evaluation.evaluate_source(
               state,
               "default",
               mission,
               ~S|(let [secret "sentinel-projection-secret"] (fail (fn [] secret)))|,
               100
             )

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: %Format.Fn{params: "..."}} = result} =
             Kernel.run(
               ~S|(let [secret "sentinel-projection-secret"] (return (fn [named-parameter] secret)))|,
               config
             )

    public_planes = inspect(%{result: result, events: EventSink.events(sink)})
    refute public_planes =~ "sentinel-projection-secret"
    refute public_planes =~ "named-parameter"
    refute public_planes =~ ":closure"
  end

  test "closure state is absent from Logger and Telemetry metadata" do
    secret = "sentinel-projection-secret"
    handler_id = "closure-projection-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:ptc_runner, :lisp, :execute, :start],
          [:ptc_runner, :lisp, :execute, :stop]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:projection_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "closure-observability")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{value: %Format.Fn{params: "..."}}} =
                 Kernel.run(
                   ~S|(let [secret "sentinel-projection-secret"] (return (fn [] secret)))|,
                   config
                 )
      end)

    assert_receive {:projection_telemetry, _start, start_measurements, start_metadata}
    assert_receive {:projection_telemetry, _stop, stop_measurements, stop_metadata}

    observability =
      inspect(%{
        log: log,
        start: {start_measurements, start_metadata},
        stop: {stop_measurements, stop_metadata},
        events: EventSink.events(sink)
      })

    refute observability =~ secret
    refute observability =~ ":closure"
  end

  test "explicit subordinate failure is recoverable and rolls back candidate memory" do
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, state} = RunState.start(Limits.defaults())

    assert %{outcome: :failed, value: "stop"} =
             Evaluation.evaluate_source(
               state,
               "default",
               mission,
               "(do (def leaked 42) (fail \"stop\"))",
               100
             )

    assert %{defined_count: 0} = RunState.evaluation_memory_summary(state)
  end

  test "subordinate ordinary return and fail outcomes commit or roll back atomically" do
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, state} = RunState.start(Limits.defaults())

    assert %{outcome: :continued, value: %Format.Var{name: "committed"}, prints: []} =
             Evaluation.evaluate_source(state, "default", mission, "(def committed 1)", 100)

    assert %{outcome: :returned, value: 2} =
             Evaluation.evaluate_source(
               state,
               "default",
               mission,
               "(def returned 2) (return returned)",
               100
             )

    assert %{outcome: :failed, value: 3} =
             Evaluation.evaluate_source(
               state,
               "default",
               mission,
               "(def leaked 3) (fail leaked)",
               100
             )

    assert %{outcome: :returned, value: [1, 2]} =
             Evaluation.evaluate_source(
               state,
               "default",
               mission,
               "(return [committed returned])",
               100
             )

    assert %{outcome: :evaluation_error} =
             Evaluation.evaluate_source(state, "default", mission, "leaked", 100)
  end

  test "subordinate continuation retains exact three-value history and rolls failures back" do
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, state} = RunState.start(Limits.defaults())

    assert %{outcome: :continued, value: 40} =
             Evaluation.evaluate_source(state, "default", mission, "40", 100)

    assert %{outcome: :continued, value: 41} =
             Evaluation.evaluate_source(state, "default", mission, "(+ *1 1)", 100)

    assert %{outcome: :returned, value: 81} =
             Evaluation.evaluate_source(state, "default", mission, "(return (+ *1 *2))", 100)

    for value <- [42, 43] do
      assert %{outcome: :continued, value: ^value} =
               Evaluation.evaluate_source(
                 state,
                 "default",
                 mission,
                 Integer.to_string(value),
                 100
               )
    end

    assert %{outcome: :evaluation_error} =
             Evaluation.evaluate_source(state, "default", mission, "(do 999 missing)", 100)

    assert %{outcome: :returned, value: [43, 42, 41]} =
             Evaluation.evaluate_source(state, "default", mission, "(return [*1 *2 *3])", 100)

    assert %{history_count: 3, history_bytes: history_bytes, bytes: combined_bytes} =
             RunState.evaluation_memory_summary(state)

    assert history_bytes > 0
    assert combined_bytes >= history_bytes
  end

  test "subordinate history preserves native callable identity behind inert observations" do
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, state} = RunState.start(Limits.defaults())

    assert %{outcome: :continued, value: %Format.Fn{params: "..."}} =
             Evaluation.evaluate_source(state, "default", mission, "(fn [x] (+ x 1))", 100)

    assert %{outcome: :returned, value: 42} =
             Evaluation.evaluate_source(state, "default", mission, "(return (*1 41))", 100)
  end

  test "ordinary evaluation errors expose capability activity and preserve committed memory" do
    parent = self()

    {:ok, touch} =
      Capability.new(
        name: "touch",
        effect: :read,
        input_schema: @input_schema,
        callback: fn _ ->
          send(parent, :mission_touch_called)
          {:ok, 42}
        end
      )

    {:ok, mission} = MissionEnvironment.new(capabilities: [touch])
    {:ok, state} = RunState.start(Limits.defaults())

    assert %{outcome: :continued} =
             Evaluation.evaluate_source(state, "default", mission, "(def retained 42)", 100)

    # `capability_activity?` is still reported, because a reviewer wants to know
    # something happened. It no longer decides retryability by itself: `touch`
    # is declared `:read`, so repeating this program repeats a read and the
    # loop's correction path stays reachable.
    activity_result =
      Evaluation.evaluate_source(
        state,
        "default",
        mission,
        ~S|(do (def leaked 99) (tool/touch {}) (+ {} 1))|,
        100
      )

    assert %{outcome: :evaluation_error, details: %{capability_activity?: true}} = activity_result
    refute Map.get(activity_result, :retryable?) == false

    assert_receive :mission_touch_called

    assert %{outcome: :returned, value: 42} =
             Evaluation.evaluate_source(state, "default", mission, "(return retained)", 100)

    assert %{outcome: :evaluation_error, details: %{capability_activity?: false}} =
             Evaluation.evaluate_source(state, "default", mission, "leaked", 100)
  end

  test "sandbox kills retain terminal provider-failure provenance outside the evaluator" do
    {:ok, blocked} =
      Capability.new(
        name: "blocked",
        effect: :read,
        input_schema: @input_schema,
        callback: fn _ ->
          {:error, ProviderError.new(:denied, "mcp_input_required_refused", retryable?: false)}
        end
      )

    {:ok, mission} = MissionEnvironment.new(capabilities: [blocked])

    {:ok, limits} =
      Limits.new(
        evaluation_timeout_ms: 500,
        evaluation_heap_words: 100_000_000
      )

    {:ok, state} = RunState.start(limits)

    result =
      Evaluation.evaluate_source(
        state,
        "default",
        mission,
        ~S|(do (tool/blocked {}) (reduce + (range 0 100000000)))|,
        500
      )

    assert %{
             outcome: :evaluation_error,
             retryable?: true,
             terminal_provider_failure?: true
           } = result

    assert result.kind in [:timeout, :memory_exceeded]
  end

  test "sandbox kills retain input-validation unavailability outside the evaluator" do
    {:ok, unstable} =
      Capability.new(
        name: "unstable",
        effect: :read,
        input_schema: @input_schema,
        callback: fn _ -> flunk("unavailable validation must prevent callback entry") end
      )

    unstable = %{unstable | input_validator: :forced_validator_failure}
    {:ok, mission} = MissionEnvironment.new(capabilities: [unstable])

    {:ok, limits} =
      Limits.new(
        evaluation_timeout_ms: 500,
        evaluation_heap_words: 100_000_000
      )

    {:ok, state} = RunState.start(limits)

    result =
      Evaluation.evaluate_source(
        state,
        "default",
        mission,
        ~S|(do (tool/unstable {}) (reduce + (range 0 100000000)))|,
        500
      )

    assert %{
             outcome: :evaluation_error,
             retryable?: true,
             terminal_host_failure?: true
           } = result

    assert result.kind in [:timeout, :memory_exceeded]
  end

  test "workflow kernel-eval routes source into the mission environment" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "kernel-eval")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok,
            %{
              value: %{
                "status" => "ok",
                "value" => %{"outcome" => "returned", "value" => 42}
              }
            }} =
             Kernel.run(
               ~S|(return (tool/kernel-eval {:mission "default" :kind :source :source "(return 42)"}))|,
               config
             )

    assert [workflow_started, mission_started, mission_stopped, workflow_stopped] =
             sink
             |> EventSink.events()
             |> Enum.filter(&(&1.type in ["evaluation-started", "evaluation-stopped"]))

    assert workflow_started.data.environment == :workflow
    assert mission_started.data.environment == :mission
    assert mission_stopped.data.environment == :mission
    assert workflow_stopped.data.environment == :workflow
  end

  test "workflow kernel-eval restores quoted-symbol identity inside the parent evaluator" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "kernel-eval-quoted-symbol")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    source = ~S"""
    (let [nested (tool/kernel-eval {:mission "default" :kind :source :source "(return 'server/tool)"})
          returned (get (get nested :value) :value)]
      (return [(= returned 'server/tool) {returned :found}]))
    """

    assert {:ok,
            %{
              value: [
                true,
                %{%Format.SymbolRef{name: "server/tool"} => "found"}
              ]
            }} = Kernel.run(source, config)
  end

  test "workflow bundle exports are attached only to the workflow evaluator" do
    {:ok, component} = Component.new(id: "workflow", source: "(ns workflow) (defn answer [] 42)")
    assert {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "bundle")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: 42}} = Kernel.run("(return (workflow/answer))", config)

    assert %{outcome: :evaluation_error} =
             Evaluation.evaluate_source(
               RunState.start(limits) |> elem(1),
               "default",
               mission,
               "(workflow/answer)",
               100
             )
  end

  test "environment assembly rejects a bundle with an ungranted tool requirement" do
    {:ok, component} =
      Component.new(
        id: "required",
        source: "(ns required) (defn call [] (tool/missing {}))"
      )

    assert {:ok, bundle} = Kernel.compile_bundle([component])

    assert {:error, {:missing_capability_requirement, ["missing"]}} =
             WorkflowEnvironment.new(bundle: bundle)
  end

  test "embedded programs cross into mission evaluation without workflow resolution" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "program")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok,
            %{
              value: %{
                "status" => "ok",
                "value" => %{"outcome" => "returned", "value" => 42}
              }
            }} =
             Kernel.run(
               "(return (tool/kernel-eval {:mission \"default\" :kind :embedded :program (program (return (+ 40 2)))}))",
               config
             )
  end

  test "dynamic and embedded workflow routes preserve ordinary and terminal classifications" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "classification-parity")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    source = """
    (let [dynamic-ordinary (tool/kernel-eval {:mission "default" :kind :source :source "(+ 1 1)"})
          embedded-ordinary (tool/kernel-eval {:mission "default" :kind :embedded :program (program (+ 2 2))})
          dynamic-return (tool/kernel-eval {:mission "default" :kind :source :source "(return 6)"})
          embedded-fail (tool/kernel-eval {:mission "default" :kind :embedded :program (program (fail 7))})]
      (return [(get dynamic-ordinary :value)
               (get embedded-ordinary :value)
               (get dynamic-return :value)
               (get embedded-fail :value)]))
    """

    assert {:ok,
            %{
              value: [
                %{"outcome" => "continued", "value" => 2},
                %{"outcome" => "continued", "value" => 4},
                %{"outcome" => "returned", "value" => 6},
                %{"outcome" => "failed", "value" => 7}
              ]
            }} = Kernel.run(source, config)
  end

  test "Program values expose only bounded opaque metadata in public results" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "program-projection")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: %{"program?" => true, "byte_size" => 7, "digest" => digest}}} =
             Kernel.run("(return (program (+ 1 2)))", config)

    assert is_binary(digest)
  end

  test "embedded programs do not capture workflow locals" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "program-local")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok,
            %{
              value: %{
                "status" => "ok",
                "value" => %{
                  "outcome" => "evaluation_error",
                  "kind" => "unbound_var"
                }
              }
            }} =
             Kernel.run(
               "(let [x 42] (return (tool/kernel-eval {:mission \"default\" :kind :embedded :program (program (return x))})))",
               config
             )
  end

  test "shipped kernel helpers keep embedded and dynamic evaluation explicit" do
    assert {:ok, kernel_component} = Library.component("kernel")
    assert {:ok, bundle} = Kernel.compile_bundle([kernel_component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "kernel-library")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    source = """
    (do
      (kernel/eval-source "default" "(def retained 40)")
      (return (kernel/eval "default" (program (return (+ retained 2))))))
    """

    assert {:ok, %{value: %{"outcome" => "returned", "value" => 42}}} =
             Kernel.run(source, config)

    {:ok, second_sink} = EventSink.start(:normal, limits, run_id: "kernel-library-invalid")

    {:ok, second_config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: second_sink
      )

    assert {:ok,
            %{
              value: %{
                "kind" => "protocol_error",
                "reason" => "invalid_kernel_eval_request"
              }
            }} =
             Kernel.run(~S|(return (kernel/eval "default" "(return 42)"))|, second_config)
  end

  test "shipped kernel helpers splice structured parameters without changing source" do
    assert {:ok, kernel_component} = Library.component("kernel")
    assert {:ok, bundle} = Kernel.compile_bundle([kernel_component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new(data: %{"params" => %{"id" => "mission"}})
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "kernel-parameters")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    source = ~S"""
    (let [dynamic-source "(return (get data/params \"id\"))"
          embedded (program (return (get data/params "id")))
          prior (kernel/eval "default" embedded)
          first (kernel/eval-source-with "default" dynamic-source {"id" "evidence-1"})
          second (kernel/eval-source-with "default" dynamic-source {"id" "evidence-2"})
          third (kernel/eval-with "default" embedded {"id" "evidence-3"})]
      (return [(get prior :value)
               (get first :value)
               (get second :value)
               (get third :value)]))
    """

    assert {:ok, %{value: ["mission", "evidence-1", "evidence-2", "evidence-3"]}} =
             Kernel.run(source, config)
  end

  test "kernel evaluation ledger arguments expose identities instead of code or parameters" do
    limits = Limits.defaults()
    source = "(return data/params)"
    params = %{"evidence_id" => "sensitive-evidence-42"}

    projected =
      RuntimeTools.kernel_eval_ledger_arguments(limits).(%{
        "kind" => :source,
        "source" => source,
        "params" => params
      })

    assert %{
             "kind" => "source",
             "source" => %{"bytes" => source_bytes, "sha256" => "sha256:" <> _},
             "params" => %{"bytes" => params_bytes, "sha256" => "sha256:" <> _}
           } = projected

    assert source_bytes == byte_size(source)
    assert params_bytes > 0
    refute inspect(projected) =~ source
    refute inspect(projected) =~ "sensitive-evidence-42"

    assert {:ok, encoded_params} = DeterministicJSON.encode(params)

    assert projected["params"]["sha256"] ==
             "sha256:" <>
               Base.encode16(:crypto.hash(:sha256, encoded_params), case: :lower)

    normalized_keyword =
      RuntimeTools.kernel_eval_ledger_arguments(limits).(%{
        "kind" => :source,
        "source" => source,
        "params" => PtcRunner.Lisp.Keyword.new("evidence-status")
      })

    assert {:ok, encoded_keyword} = DeterministicJSON.encode("evidence-status")

    assert normalized_keyword["params"]["sha256"] ==
             "sha256:" <>
               Base.encode16(:crypto.hash(:sha256, encoded_keyword), case: :lower)

    oversized = String.duplicate("x", limits.subordinate_source_bytes + 1)

    assert %{"source" => %{"bytes" => bytes}} =
             RuntimeTools.kernel_eval_ledger_arguments(limits).(%{
               "kind" => :source,
               "source" => oversized
             })

    assert bytes == byte_size(oversized)

    refute Map.has_key?(
             RuntimeTools.kernel_eval_ledger_arguments(limits).(%{
               "kind" => :source,
               "source" => oversized
             })["source"],
             "sha256"
           )

    oversized_params = String.duplicate("p", limits.capability_argument_bytes + 1)

    assert %{"params" => %{"invalid" => true}} =
             RuntimeTools.kernel_eval_ledger_arguments(limits).(%{
               "kind" => :source,
               "source" => source,
               "params" => oversized_params
             })
  end

  test "invalid structured evaluation parameters do not consume evaluation quota" do
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, state} = RunState.start(Limits.defaults())
    limits = Limits.defaults()

    callback =
      RuntimeTools.kernel_eval(state, %{"default" => mission}, limits, nil)

    assert %{
             status: :error,
             kind: :protocol_error,
             reason: :invalid_kernel_eval_request
           } =
             callback.(%{
               "kind" => :embedded,
               "program" => Program.new("(return data/params)"),
               "params" => Program.new("(return 42)")
             })

    assert %{subordinate_evaluations: 0, protocol_errors: 1} = RunState.usage(state)
  end

  test "kernel source checks use the frozen mission compiler without executing code" do
    assert {:ok, kernel_component} = Library.component("kernel")
    assert {:ok, bundle} = Kernel.compile_bundle([kernel_component])
    parent = self()

    {:ok, lookup} =
      Capability.new(
        name: "lookup",
        effect: :read,
        input_schema: @input_schema,
        callback: fn _arguments ->
          send(parent, :source_check_executed_capability)
          {:ok, 42}
        end
      )

    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new(capabilities: [lookup])
    {:ok, limits} = Limits.new(subordinate_source_checks: 2)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "kernel-source-check")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    source = ~S"""
    (let [valid (kernel/check-source "default" "(return (tool/lookup {}))")
          invalid (kernel/check-source "default" "(return (tool/missing {}))")
          usage (tool/runtime-usage {})]
      (return [valid invalid usage]))
    """

    assert {:ok, %{value: [valid, invalid, usage]}} = Kernel.run(source, config)

    assert %{
             "outcome" => "valid",
             "source_bytes" => valid_bytes,
             "source_hash" => "sha256:" <> _
           } = valid

    assert valid_bytes == byte_size("(return (tool/lookup {}))")

    assert %{
             "outcome" => "invalid",
             "diagnostic" => %{
               "kind" => "unknown_tool",
               "message" => diagnostic,
               "details" => %{}
             }
           } = invalid

    assert is_binary(diagnostic)
    assert usage["subordinate_source_checks"] == 2
    assert usage["subordinate_evaluations"] == 0
    refute_received :source_check_executed_capability
  end

  test "invalid and oversized source-check requests do not consume check quota or hash oversized code" do
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, state} = RunState.start(limits)

    callback =
      RuntimeTools.kernel_check_source(
        state,
        %{"default" => mission},
        limits,
        nil
      )

    assert %{status: :error, reason: :invalid_kernel_check_source_request} = callback.(%{})

    oversized = String.duplicate("x", limits.subordinate_source_bytes + 1)

    assert %{status: :ok, value: %{outcome: :limit_exceeded, source_bytes: bytes} = result} =
             callback.(%{"mission" => "default", "source" => oversized})

    assert bytes == byte_size(oversized)
    refute Map.has_key?(result, :source_hash)
    assert %{subordinate_source_checks: 0, protocol_errors: 1} = RunState.usage(state)
  end

  test "source-check diagnostics match subsequent mission compilation failures" do
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(subordinate_source_checks: 3, subordinate_evaluations: 3)
    {:ok, state} = RunState.start(limits)

    callback =
      RuntimeTools.kernel_check_source(
        state,
        %{"default" => mission},
        limits,
        nil
      )

    for source <- ["(unclosed", "missing", "(tool/missing {})"] do
      assert %{status: :ok, value: %{outcome: :invalid, diagnostic: diagnostic}} =
               callback.(%{"mission" => "default", "source" => source})

      assert %{outcome: :evaluation_error, kind: kind, details: %{message: message}} =
               Evaluation.evaluate_source(state, "default", mission, source, 1_000)

      assert diagnostic.kind == kind
      assert diagnostic.message == message
    end

    assert %{subordinate_source_checks: 3, subordinate_evaluations: 3} = RunState.usage(state)
  end

  test "source-check diagnostics truncate multi-codepoint graphemes by bytes" do
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, state} = RunState.start(limits)
    grapheme = "👨‍👩‍👧‍👦"
    source = "(quote [\"#{String.duplicate(grapheme, 300)}\"])"

    assert %{outcome: :invalid, diagnostic: %{message: message}} =
             SourceCheck.check(state, "default", mission, source, limits, nil)

    assert byte_size(message) in 4_000..4_096
    assert String.valid?(message)
  end

  test "source checks preserve production symbol, timeout, and compiler-heap classifications" do
    {:ok, mission} = MissionEnvironment.new([])

    many_symbols =
      "(do " <> Enum.map_join(1..10_001, " ", &("symbol" <> Integer.to_string(&1))) <> ")"

    cases = [
      {many_symbols, [], :symbol_limit_exceeded, :invalid},
      {"(let [x 1] (+ x 2))", [evaluation_heap_words: 300], :compile_memory_exceeded,
       :limit_exceeded}
    ]

    for {source, overrides, reason, outcome} <- cases do
      {:ok, limits} = Limits.new(overrides)
      {:ok, check_state} = RunState.start(limits)
      {:ok, evaluation_state} = RunState.start(limits)

      checked = SourceCheck.check(check_state, "default", mission, source, limits, nil)
      checked_reason = get_in(checked, [:diagnostic, :kind]) || Map.get(checked, :reason)

      assert checked.outcome == outcome
      assert checked_reason == reason

      assert %{outcome: :evaluation_error, kind: ^reason} =
               Evaluation.evaluate_source(
                 evaluation_state,
                 "default",
                 mission,
                 source,
                 limits.evaluation_timeout_ms
               )
    end

    limits = Limits.defaults()
    {:ok, timeout_state} = RunState.start(limits)

    assert %{outcome: :limit_exceeded, reason: :compile_timeout} =
             SourceCheck.check(timeout_state, "default", mission, "42", limits, nil,
               compile_timeout: 0
             )

    assert {:error, %{fail: %{reason: :compile_timeout}}} =
             PtcRunner.Lisp.run_native("42", compile_timeout: 0)
  end

  test "source checks resolve only committed continuation definitions" do
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, state} = RunState.start(Limits.defaults())

    assert %{outcome: :continued} =
             Evaluation.evaluate_source(state, "default", mission, "(def retained 42)", 1_000)

    assert %{outcome: :valid} =
             SourceCheck.check(
               state,
               "default",
               mission,
               "(return retained)",
               Limits.defaults(),
               nil
             )

    assert %{outcome: :evaluation_error, kind: :unbound_var} =
             Evaluation.evaluate_source(
               state,
               "default",
               mission,
               "(do (def leaked 9) (+ missing 1))",
               1_000
             )

    assert %{outcome: :invalid, diagnostic: %{kind: :unbound_var}} =
             SourceCheck.check(
               state,
               "default",
               mission,
               "(return leaked)",
               Limits.defaults(),
               nil
             )

    assert %{outcome: :valid} =
             SourceCheck.check(
               state,
               "default",
               mission,
               "(return retained)",
               Limits.defaults(),
               nil
             )
  end

  test "source-check finish rejects a compile result after continuation commit or closure" do
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, state} = RunState.start(limits)
    parent = self()

    checking =
      Task.async(fn ->
        SourceCheck.check(state, "default", mission, "(return 42)", limits, nil,
          after_compile: fn ->
            send(parent, :source_compiled)

            receive do
              :finish_source_check -> :ok
            end
          end
        )
      end)

    assert_receive :source_compiled
    assert {:ok, %{}, [], lease} = RunState.reserve_evaluation(state, "default", :fail_fast)
    assert :ok = RunState.commit_evaluation(state, lease, %{"changed" => true}, [])
    send(checking.pid, :finish_source_check)

    assert %{outcome: :stale, reason: :continuation_changed} = Task.await(checking)

    assert %{outcome: :limit_exceeded, reason: :run_closed} =
             SourceCheck.check(state, "default", mission, "42", limits, nil,
               after_compile: fn -> RunState.close(state) end
             )
  end

  test "runtime discovery and workflow annotation helpers expose bounded host facts" do
    assert {:ok, components} = Library.components(["runtime", "cap", "workflow.event"])
    assert {:ok, bundle} = Kernel.compile_bundle(components)

    {:ok, search} =
      Capability.new(
        name: "search",
        description: "Search a fixed fixture",
        input_schema: @input_schema,
        callback: fn _ -> {:ok, []} end
      )

    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [search])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "runtime-library")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    source = """
    (do
      (workflow.event/annotate "progress" {:stage "started"})
      (return {:remaining (runtime/remaining)
               :usage (runtime/usage)
               :capabilities (cap/list)
               :search (cap/describe "search")}))
    """

    assert {:ok, %{value: value}} = Kernel.run(source, config)
    assert is_integer(value["remaining"])
    assert is_map(value["usage"])
    assert [%{"name" => "search"}] = value["capabilities"]

    assert %{"name" => "search", "description" => "Search a fixed fixture"} =
             value["search"]

    assert %{type: "workflow-annotation", data: %{annotation_type: "progress"}} =
             Enum.find(EventSink.events(sink), &(&1.type == "workflow-annotation"))

    config_for = fn run_id ->
      {:ok, next_sink} = EventSink.start(:normal, limits, run_id: run_id)

      {:ok, next_config} =
        RunConfig.new(
          workflow_environment: workflow,
          missions: %{"default" => mission},
          input: %{},
          limits: limits,
          event_sink: next_sink
        )

      {next_config, next_sink}
    end

    private = "PRIVATE_GENERATED_SOURCE_(return_42)"
    {private_config, private_sink} = config_for.("runtime-library-private")

    assert {:ok,
            %{
              value: %{
                "status" => "error",
                "kind" => "invalid_annotation",
                "reason" => "invalid_workflow_annotation"
              }
            }} =
             Kernel.run(
               ~s|(return (workflow.event/annotate "progress" {"stage" "started" "source" "#{private}"}))|,
               private_config
             )

    prompt = "SECRET_PROMPT"
    session = "session-123"
    {prompt_config, prompt_sink} = config_for.("runtime-library-prompt")

    assert {:ok,
            %{
              value: %{
                "status" => "error",
                "kind" => "invalid_annotation",
                "reason" => "invalid_workflow_annotation"
              }
            }} =
             Kernel.run(
               ~s|(return (workflow.event/annotate "progress" {"prompt" "#{prompt}" "session_id" "#{session}"}))|,
               prompt_config
             )

    {malformed_config, _malformed_sink} = config_for.("runtime-library-malformed")

    assert {:ok,
            %{
              value: %{
                "status" => "error",
                "kind" => "protocol_error",
                "reason" => "invalid_workflow_annotation"
              }
            }} =
             Kernel.run(
               ~s|(return (tool/workflow-annotate {}))|,
               malformed_config
             )

    {rejection_config, rejection_sink} = config_for.("runtime-library-rejections")

    rejected_calls =
      Enum.map_join(1..(limits.protocol_errors + 1), "\n", fn _attempt ->
        ~s|(workflow.event/annotate "progress" {"source" "private"})|
      end)

    assert {:ok, %{value: %{"closed?" => false, "protocol_errors" => 0}}} =
             Kernel.run(
               """
               (do
                 #{rejected_calls}
                 (return (runtime/usage)))
               """,
               rejection_config
             )

    refute Enum.any?(
             EventSink.events(rejection_sink),
             &(&1.type == "workflow-annotation")
           )

    public_events =
      EventSink.events(sink) ++ EventSink.events(private_sink) ++ EventSink.events(prompt_sink)

    encoded_events = Jason.encode!(public_events)
    refute String.contains?(encoded_events, private)
    refute String.contains?(encoded_events, prompt)
    refute String.contains?(encoded_events, session)
  end

  test "terminal workflow results and retained mission memory use Kernel limits and state" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(terminal_result_bytes: 1)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "terminal-limit")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:error, %{kind: :limit_exceeded, reason: :terminal_result_exceeded}} =
             Kernel.run("(return 42)", config)

    assert %{type: "limit-exceeded", data: %{reason: :terminal_result_exceeded}} =
             Enum.find(EventSink.events(sink), &(&1.type == "limit-exceeded"))

    {:ok, retained_limits} = Limits.new(run_duration_ms: 120_000)
    {:ok, state} = RunState.start(retained_limits)

    assert %{outcome: :continued} =
             Evaluation.evaluate_source(state, "default", mission, "(def retained 42)", 100)

    assert %{defined_count: 1, bytes: bytes} = RunState.evaluation_memory_summary(state)
    assert bytes > 0
  end

  test "environment constructors reject forged bundles and non-JSON mission data" do
    assert {:error, :invalid_bundle} = WorkflowEnvironment.new(bundle: %{})
    assert {:error, :invalid_bundle} = MissionEnvironment.new(bundle: %{prelude: %{}})

    assert {:error, :invalid_environment_data} =
             MissionEnvironment.new(data: %{"callback" => fn -> :ok end})

    assert {:error, :invalid_environment_data} = MissionEnvironment.new(data: [])

    assert {:error, :invalid_environment_data} =
             MissionEnvironment.new(data: %{"text" => <<255>>})

    forged = %FrozenBundle{components: [], component_ids: [], hash: "forged", prelude: nil}
    assert {:error, :invalid_bundle} = WorkflowEnvironment.new(bundle: forged)
  end

  test "protocol errors exhaust their hard run limit" do
    {:ok, capability} =
      Capability.new(
        name: "checked",
        input_schema: @input_schema,
        callback: fn _ -> {:ok, nil} end,
        validate: fn _ -> {:error, :invalid} end
      )

    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, limits} = Limits.new(protocol_errors: 1)
    {:ok, state} = RunState.start(limits)

    assert %{kind: :protocol_error} =
             Dispatcher.dispatch(
               state,
               :workflow,
               environment,
               "checked",
               %{},
               TestHelpers.dispatch_context(state, :workflow, 100),
               nil,
               nil
             )

    assert %{kind: :limit_exceeded, reason: :protocol_errors} =
             Dispatcher.dispatch(
               state,
               :workflow,
               environment,
               "checked",
               %{},
               TestHelpers.dispatch_context(state, :workflow, 100),
               nil,
               nil
             )

    assert %{closed?: true, protocol_errors: 2} = RunState.usage(state)
  end

  test "provider completion atomically releases its slot and rejects a closed run" do
    {:ok, limits} = Limits.new(live_provider_tasks: 1)
    {:ok, state} = RunState.start(limits)
    assert :ok = RunState.reserve_capability(state, :workflow, "read")
    assert :ok = RunState.close(state)
    assert {:error, :run_closed} = RunState.finish_provider(state)
  end

  defp dispatch_after_provider_down(state, dispatch) do
    tracker = state.provider_tracker.pid
    :ok = :sys.suspend(tracker)

    task =
      Task.async(fn ->
        receive do
          :dispatch -> dispatch.()
        end
      end)

    try do
      send(task.pid, :dispatch)

      assert_eventually(fn -> is_pid(pending_provider_attachment(tracker)) end)
      provider = pending_provider_attachment(tracker)
      provider_ref = Process.monitor(provider)
      assert_receive {:DOWN, ^provider_ref, :process, ^provider, _reason}

      :ok = :sys.resume(tracker)
      Task.await(task)
    after
      if Process.alive?(tracker), do: :sys.resume(tracker)
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end
  end

  defp pending_provider_attachment(tracker) do
    {:messages, messages} = Process.info(tracker, :messages)

    Enum.find_value(messages, fn
      {:"$gen_call", _from, {_token, {:attach, provider}}} -> provider
      _message -> nil
    end)
  end
end
