defmodule PtcRunner.Kernel.CoreContractTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.ResultArtifact
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.Runner
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.RetainedSize

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
  end

  test "capability quota reservation is total and per-name atomic" do
    {:ok, limits} =
      Limits.new(workflow_capability_calls: 1, workflow_capability_calls_per_name: 1)

    {:ok, state} = RunState.start(limits)

    assert :ok = RunState.reserve_capability(state, :workflow, "read")
    assert {:error, :limit_exceeded} = RunState.reserve_capability(state, :workflow, "read")
    assert {:error, :limit_exceeded} = RunState.reserve_capability(state, :workflow, "other")
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
    assert {:ok, %{}, [], lease} = RunState.reserve_evaluation(state)
    assert {:error, :busy} = RunState.reserve_evaluation(state)
    assert :ok = RunState.release_evaluation(state, lease)
    assert {:ok, %{}, [], next_lease} = RunState.reserve_evaluation(state)
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
    assert {:ok, %{}, [], first_lease} = RunState.reserve_evaluation(state)
    assert :ok = RunState.commit_evaluation(state, first_lease, memory, [])

    assert {:ok, ^memory, [], history_lease} = RunState.reserve_evaluation(state)
    assert :ok = RunState.commit_evaluation(state, history_lease, memory, [history_value])

    assert %{
             memory_bytes: ^memory_limit,
             history_bytes: ^history_limit,
             bytes: combined_bytes
           } = RunState.evaluation_memory_summary(state)

    assert combined_bytes > memory_limit

    assert {:ok, ^memory, [^history_value], rejected_lease} =
             RunState.reserve_evaluation(state)

    assert {:error, :history_exceeded} =
             RunState.commit_evaluation(
               state,
               rejected_lease,
               memory,
               [history_value, "overflow"]
             )

    assert {:ok, ^memory, [^history_value], release_lease} =
             RunState.reserve_evaluation(state)

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
    assert {:ok, %{}, [], lease} = RunState.reserve_evaluation(state)
    assert :ok = RunState.commit_evaluation(state, lease, %{"slice" => slice}, [slice])

    assert {:ok, %{"slice" => retained}, [history], next_lease} =
             RunState.reserve_evaluation(state)

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
             Dispatcher.dispatch(state, :workflow, environment, "unavailable", %{}, 100)

    assert %{status: :error, kind: :result_exceeded, reason: :provider_result_limit} =
             Dispatcher.dispatch(state, :workflow, environment, "invalid", %{}, 100)

    assert %{status: :error, kind: :result_exceeded, reason: :provider_result_limit} =
             Dispatcher.dispatch(state, :workflow, environment, "malformed-struct", %{}, 100)
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

    assert %{status: :error, kind: :timeout, reason: :provider_timeout} =
             Dispatcher.dispatch(state, :workflow, environment, "slow", %{}, 1)

    assert_received :started
    assert :ok = RunState.close(state)

    assert %{status: :error, kind: :limit_exceeded, reason: :run_closed} =
             Dispatcher.dispatch(state, :workflow, environment, "slow", %{}, 100)
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
      Task.async(fn -> Dispatcher.dispatch(state, :workflow, environment, "gate", %{}, 1_000) end)

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
      spawn(fn -> Dispatcher.dispatch(state, :workflow, environment, "slow", %{}, 30_000) end)

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
        Dispatcher.dispatch(state, :workflow, environment, "slow", %{}, 30_000)
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
        mission_environment: mission,
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
        mission_environment: mission,
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
        mission_environment: mission,
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
        mission_environment: mission,
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
               mission_environment: mission,
               input: %{},
               limits: limits,
               event_sink: sink
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
              mission_environment: mission,
              input: %{},
              limits: limits,
              event_sink: sink,
              provider_resources: [close]
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
              mission_environment: mission,
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
               mission_environment: mission,
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
        event_payload_bytes: 5_900,
        normal_event_count: 4,
        normal_event_bytes: 100_000
      )

    {:ok, sink} = EventSink.start(:normal, limits)

    assert {:ok, _config} =
             RunConfig.new(
               workflow_environment: workflow,
               mission_environment: mission,
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
                 mission_environment: mission,
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
               mission_environment: mission,
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
        mission_environment: mission,
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
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink,
        provider_resources: [
          fn ->
            send(parent, :resource_closed)
            :ok
          end
        ]
      )

    first = Task.async(fn -> Kernel.run("(return (tool/blocking {}))", config) end)
    assert_receive {:provider_started, provider}

    assert {:error, %{kind: :event_sink_error, reason: :event_sink_error}} =
             Kernel.run("(return 43)", config)

    refute_receive :resource_closed

    send(provider, :continue)
    assert {:ok, %{value: %{status: :ok, value: 42}}} = Task.await(first)
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
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink,
        provider_resources: [
          fn ->
            send(parent, close_message)
            :ok
          end
        ]
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
    assert {:ok, %{value: %{status: :ok, value: 42}}} = Task.await(winner)
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
        mission_environment: mission,
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
        mission_environment: mission,
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
        mission_environment: mission,
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
        mission_environment: mission,
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
               mission,
               "(do (def parser Boolean/parseBoolean) parser)",
               100
             )

    assert %{defined_count: 0, history_count: 0} = RunState.evaluation_memory_summary(state)
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
          mission_environment: mission,
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
               Evaluation.evaluate_source_detailed(
                 state,
                 mission,
                 expression,
                 100,
                 nil,
                 nil
               )

      assert %{defined_count: 0, history_count: 0} =
               RunState.evaluation_memory_summary(state)
    end
  end

  test "explicit workflow failure returns the outer error algebra" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "workflow-fail")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    private = "PRIVATE_GENERATED_SOURCE_(return_42)"

    assert {:error, %{kind: :workflow_failed, reason: :explicit_failure} = error} =
             Kernel.run(~s|(fail "#{private}")|, config)

    refute inspect(error) =~ private
  end

  test "explicit workflow failure exposes only bounded safe taxonomy" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "workflow-failure-taxonomy")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
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
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: %{status: :ok, value: %{"sum" => 42}}}} =
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
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: %{status: :error, kind: :protocol_error, reason: :ambiguous_arguments}}} =
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

    assert %{outcome: :returned, value: %{kind: :protocol_error, reason: :ambiguous_arguments}} =
             Evaluation.evaluate_source(
               state,
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
                 mission,
                 ~S|(do (tool/commit {}) (reduce (fn [acc i] (conj acc (range 0 4096))) [] (range 0 4096)))|,
                 5_000
               ),
             "effect #{inspect(effect)} must keep a resource kill terminal"
    end
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
             Evaluation.evaluate_source(state, mission, "(def x 40)", 100)

    assert %{outcome: :returned, value: 42} =
             Evaluation.evaluate_source(state, mission, "(return (+ x 2))", 100)

    assert %{outcome: :evaluation_error} =
             Evaluation.evaluate_source(state, mission, "(tool/workflow-only {})", 100)

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
               mission,
               ~S|(let [secret "sentinel-projection-secret"] (fn [named-parameter] secret))|,
               100
             )

    assert %{outcome: :failed, value: %Format.Fn{params: "..."}} =
             Evaluation.evaluate_source(
               state,
               mission,
               ~S|(let [secret "sentinel-projection-secret"] (fail (fn [] secret)))|,
               100
             )

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
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
        mission_environment: mission,
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
             Evaluation.evaluate_source(state, mission, "(def committed 1)", 100)

    assert %{outcome: :returned, value: 2} =
             Evaluation.evaluate_source(
               state,
               mission,
               "(def returned 2) (return returned)",
               100
             )

    assert %{outcome: :failed, value: 3} =
             Evaluation.evaluate_source(
               state,
               mission,
               "(def leaked 3) (fail leaked)",
               100
             )

    assert %{outcome: :returned, value: [1, 2]} =
             Evaluation.evaluate_source(state, mission, "(return [committed returned])", 100)

    assert %{outcome: :evaluation_error} =
             Evaluation.evaluate_source(state, mission, "leaked", 100)
  end

  test "subordinate continuation retains exact three-value history and rolls failures back" do
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, state} = RunState.start(Limits.defaults())

    assert %{outcome: :continued, value: 40} =
             Evaluation.evaluate_source(state, mission, "40", 100)

    assert %{outcome: :continued, value: 41} =
             Evaluation.evaluate_source(state, mission, "(+ *1 1)", 100)

    assert %{outcome: :returned, value: 81} =
             Evaluation.evaluate_source(state, mission, "(return (+ *1 *2))", 100)

    for value <- [42, 43] do
      assert %{outcome: :continued, value: ^value} =
               Evaluation.evaluate_source(state, mission, Integer.to_string(value), 100)
    end

    assert %{outcome: :evaluation_error} =
             Evaluation.evaluate_source(state, mission, "(do 999 missing)", 100)

    assert %{outcome: :returned, value: [43, 42, 41]} =
             Evaluation.evaluate_source(state, mission, "(return [*1 *2 *3])", 100)

    assert %{history_count: 3, history_bytes: history_bytes, bytes: combined_bytes} =
             RunState.evaluation_memory_summary(state)

    assert history_bytes > 0
    assert combined_bytes >= history_bytes
  end

  test "subordinate history preserves native callable identity behind inert observations" do
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, state} = RunState.start(Limits.defaults())

    assert %{outcome: :continued, value: %Format.Fn{params: "..."}} =
             Evaluation.evaluate_source(state, mission, "(fn [x] (+ x 1))", 100)

    assert %{outcome: :returned, value: 42} =
             Evaluation.evaluate_source(state, mission, "(return (*1 41))", 100)
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
             Evaluation.evaluate_source(state, mission, "(def retained 42)", 100)

    # `capability_activity?` is still reported, because a reviewer wants to know
    # something happened. It no longer decides retryability by itself: `touch`
    # is declared `:read`, so repeating this program repeats a read and the
    # loop's correction path stays reachable.
    activity_result =
      Evaluation.evaluate_source(
        state,
        mission,
        ~S|(do (def leaked 99) (tool/touch {}) (+ {} 1))|,
        100
      )

    assert %{outcome: :evaluation_error, details: %{capability_activity?: true}} = activity_result
    refute Map.get(activity_result, :retryable?) == false

    assert_receive :mission_touch_called

    assert %{outcome: :returned, value: 42} =
             Evaluation.evaluate_source(state, mission, "(return retained)", 100)

    assert %{outcome: :evaluation_error, details: %{capability_activity?: false}} =
             Evaluation.evaluate_source(state, mission, "leaked", 100)
  end

  test "workflow kernel-eval routes source into the mission environment" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "kernel-eval")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: %{status: :ok, value: %{outcome: :returned, value: 42}}}} =
             Kernel.run(
               "(return (tool/kernel-eval {:kind :source :source \"(return 42)\"}))",
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
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: 42}} = Kernel.run("(return (workflow/answer))", config)

    assert %{outcome: :evaluation_error} =
             Evaluation.evaluate_source(
               RunState.start(limits) |> elem(1),
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
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: %{status: :ok, value: %{outcome: :returned, value: 42}}}} =
             Kernel.run(
               "(return (tool/kernel-eval {:kind :embedded :program (program (return (+ 40 2)))}))",
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
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    source = """
    (let [dynamic-ordinary (tool/kernel-eval {:kind :source :source "(+ 1 1)"})
          embedded-ordinary (tool/kernel-eval {:kind :embedded :program (program (+ 2 2))})
          dynamic-return (tool/kernel-eval {:kind :source :source "(return 6)"})
          embedded-fail (tool/kernel-eval {:kind :embedded :program (program (fail 7))})]
      (return [(get dynamic-ordinary :value)
               (get embedded-ordinary :value)
               (get dynamic-return :value)
               (get embedded-fail :value)]))
    """

    assert {:ok,
            %{
              value: [
                %{outcome: :continued, value: 2},
                %{outcome: :continued, value: 4},
                %{outcome: :returned, value: 6},
                %{outcome: :failed, value: 7}
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
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: %{program?: true, byte_size: 7, digest: digest}}} =
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
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok,
            %{value: %{status: :ok, value: %{outcome: :evaluation_error, kind: :unbound_var}}}} =
             Kernel.run(
               "(let [x 42] (return (tool/kernel-eval {:kind :embedded :program (program (return x))})))",
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
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    source = """
    (do
      (kernel/eval-source "(def retained 40)")
      (return (kernel/eval (program (return (+ retained 2))))))
    """

    assert {:ok, %{value: %{outcome: :returned, value: 42}}} = Kernel.run(source, config)

    {:ok, second_sink} = EventSink.start(:normal, limits, run_id: "kernel-library-invalid")

    {:ok, second_config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: second_sink
      )

    assert {:ok, %{value: %{kind: :protocol_error, reason: :invalid_kernel_eval_request}}} =
             Kernel.run("(return (kernel/eval \"(return 42)\"))", second_config)
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
        mission_environment: mission,
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
    assert [%{name: "search"}] = value["capabilities"]
    assert %{name: "search", description: "Search a fixed fixture"} = value["search"]

    assert %{type: "workflow-annotation", data: %{annotation_type: "progress"}} =
             Enum.find(EventSink.events(sink), &(&1.type == "workflow-annotation"))

    config_for = fn run_id ->
      {:ok, next_sink} = EventSink.start(:normal, limits, run_id: run_id)

      {:ok, next_config} =
        RunConfig.new(
          workflow_environment: workflow,
          mission_environment: mission,
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
                status: :error,
                kind: :invalid_annotation,
                reason: :invalid_workflow_annotation
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
                status: :error,
                kind: :invalid_annotation,
                reason: :invalid_workflow_annotation
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
                status: :error,
                kind: :protocol_error,
                reason: :invalid_workflow_annotation
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

    assert {:ok, %{value: %{closed?: false, protocol_errors: 0}}} =
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
        mission_environment: mission,
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
             Evaluation.evaluate_source(state, mission, "(def retained 42)", 100)

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
             Dispatcher.dispatch(state, :workflow, environment, "checked", %{}, 100)

    assert %{kind: :limit_exceeded, reason: :protocol_errors} =
             Dispatcher.dispatch(state, :workflow, environment, "checked", %{}, 100)

    assert %{closed?: true, protocol_errors: 2} = RunState.usage(state)
  end

  test "provider completion atomically releases its slot and rejects a closed run" do
    {:ok, limits} = Limits.new(live_provider_tasks: 1)
    {:ok, state} = RunState.start(limits)
    assert :ok = RunState.reserve_capability(state, :workflow, "read")
    assert :ok = RunState.close(state)
    assert {:error, :run_closed} = RunState.finish_provider(state)
  end
end
