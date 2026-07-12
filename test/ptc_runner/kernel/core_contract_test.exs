defmodule PtcRunner.Kernel.CoreContractTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment

  test "environment constructors reject duplicate and mission-reserved capability names" do
    assert {:ok, capability} =
             Capability.new(name: "read", callback: fn _ -> {:ok, %{"ok" => true}} end)

    assert {:error, :duplicate_capability} =
             WorkflowEnvironment.new(capabilities: [capability, capability])

    assert {:ok, reserved} = Capability.new(name: "kernel-eval", callback: fn _ -> {:ok, nil} end)
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

  test "only one evaluation lease is granted and failed candidates preserve memory" do
    {:ok, limits} = Limits.new(subordinate_evaluations: 2, evaluation_memory_bytes: 1_000)
    {:ok, state} = RunState.start(limits)
    assert {:ok, %{}, lease} = RunState.reserve_evaluation(state)
    assert {:error, :busy} = RunState.reserve_evaluation(state)
    assert :ok = RunState.release_evaluation(state, lease)
    assert {:ok, %{}, next_lease} = RunState.reserve_evaluation(state)
    assert :ok = RunState.commit_evaluation(state, next_lease, %{"x" => 42})
    assert %{evaluation_memory_bytes: memory_bytes} = RunState.usage(state)
    assert memory_bytes > 0
  end

  test "dispatcher contains provider errors and rejects invalid returns" do
    assert {:ok, unavailable} =
             Capability.new(
               name: "unavailable",
               callback: fn _ ->
                 {:error, ProviderError.new(:unavailable, "try later", retryable?: true)}
               end
             )

    assert {:ok, invalid} = Capability.new(name: "invalid", callback: fn _ -> {:ok, self()} end)
    assert {:ok, environment} = WorkflowEnvironment.new(capabilities: [unavailable, invalid])
    {:ok, state} = RunState.start(Limits.defaults())

    assert %{status: :error, kind: :provider_error, reason: :unavailable, retryable?: true} =
             Dispatcher.dispatch(state, :workflow, environment, "unavailable", %{}, 100)

    assert %{status: :error, kind: :result_exceeded, reason: :provider_result_limit} =
             Dispatcher.dispatch(state, :workflow, environment, "invalid", %{}, 100)
  end

  test "timed-out provider results cannot consume another callback slot after closure" do
    parent = self()

    {:ok, capability} =
      Capability.new(
        name: "slow",
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

  test "normal event sinks drop while private event sinks fail closed" do
    {:ok, limits} = Limits.new(normal_event_count: 1, normal_event_bytes: 100)
    {:ok, normal} = EventSink.start(:normal, limits, run_id: "normal")
    {:ok, private} = EventSink.start(:private, limits, run_id: "private")

    assert :ok = EventSink.emit(normal, "run-started", %{"safe" => true})
    assert :ok = EventSink.emit(normal, "run-stopped", %{"safe" => true})
    assert %{"run-stopped" => 1} = EventSink.dropped(normal)

    assert :ok = EventSink.emit(private, "run-started", %{"safe" => true})
    assert {:error, :event_sink_error} = EventSink.emit(private, "run-stopped", %{"safe" => true})
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

    assert [%{type: "run-started"}, %{type: "run-stopped"}] = EventSink.events(sink)
  end
end
