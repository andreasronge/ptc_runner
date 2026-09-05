defmodule PtcRunner.Kernel.ReplSessionTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers, only: [long_running_body: 1]

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventBudget
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.ReplSessionOwner
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.ProviderSessionFixture
  alias PtcRunner.TestSupport.StreamingInspection

  @input_schema %{"type" => "object", "additionalProperties" => true}

  # A REPL form is an evaluation like any other, so the same boundary it hits
  # has to leave the same public count behind.
  test "a denied REPL form is counted in session usage" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-denial")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)

    assert %{capability_denials: %{}} = ReplSession.usage(session)

    assert {:error, %{fail: %{reason: :unknown_tool}}, session} =
             ReplSession.eval(session, ~S|(tool/vault.read {})|)

    assert %{capability_denials: %{"unknown_tool" => 1}} = ReplSession.usage(session)
  end

  test "workflow-authorized REPL tools validate under the evaluation heap" do
    {:ok, checked} =
      Capability.new(
        name: "checked",
        input_schema: %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "integer"}},
          "required" => ["value"]
        },
        callback: fn %{"value" => value} -> {:ok, %{"accepted" => value}} end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [checked])
    {:ok, mission} = MissionEnvironment.new([])

    # The deliberately tiny workflow ceiling makes the old authority-derived
    # validator worker fail. REPL Lisp and its tool validation both belong to
    # the evaluation resource class and must use that larger ceiling.
    {:ok, limits} = Limits.new(workflow_heap_words: 233)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-validation-heap")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)

    assert {:ok, step, session} =
             ReplSession.eval(session, ~S|(tool/checked {"value" 1})|)

    assert step.return == %{status: :ok, value: %{"accepted" => 1}}

    assert {:ok, _events} = ReplSession.close(session)
  end

  test "manifest sessions grant the Runner's workflow runtime tools" do
    # A reused manifest bundle must mean the same thing in the REPL as in the
    # Runner: shipped preludes require runtime tools (workflow-annotate,
    # runtime-usage), and fail-closed attach rejects a session missing them.
    names =
      ~w(agent.core agent.failure agent.feedback agent.machine agent.native agent.prompt agent.retry kernel llm result workflow.event)

    {:ok, components} = Library.components(names)
    {:ok, bundle} = Kernel.compile_bundle(components)

    {:ok, llm} =
      LLMCapability.new(
        requester: fn _request ->
          {:ok, %{content: "unused", tokens: %{input: 0, output: 0}}}
        end
      )

    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [llm])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-manifest-tools")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)

    assert {:ok, step, session} =
             ReplSession.eval(
               session,
               ~S|(workflow.event/annotate "agent-action" {:turn 0 :max-turns 1 :kind "tool-call"})|
             )

    assert step.return[:status] == :ok or step.return["status"] == "ok"

    assert {:ok, agent_step, _session} =
             ReplSession.eval(
               session,
               ~S|(if false (agent.core/run-value "unused" {"max_turns" 1}) :agent-route-ready)|
             )

    assert agent_step.return == "agent-route-ready"

    assert Enum.any?(EventSink.events(sink), fn event ->
             event.type == "workflow-annotation" and
               event.data.annotation_type == "agent-action"
           end)
  end

  test "manifest sessions redact kernel evaluation ledger arguments" do
    {:ok, component} = Library.component("kernel")
    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-kernel-ledger")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)

    assert {:ok, step, _session} =
             ReplSession.eval(
               session,
               ~S|(tool/kernel-eval {:mission "default" :kind :source :source "(return 42)" :params {"id" "secret-evidence"}})|
             )

    assert [%{name: "kernel-eval", args: arguments}] = step.tool_calls

    assert %{"source" => %{"sha256" => "sha256:" <> _}, "params" => %{"sha256" => _}} =
             arguments

    refute inspect(arguments) =~ "(return 42)"
    refute inspect(arguments) =~ "secret-evidence"
  end

  test "manifest REPL source checks run while the workflow continuation is yielded" do
    {:ok, component} = Library.component("kernel")
    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-source-check")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)

    assert {:ok, %{return: check}, _session} =
             ReplSession.eval(session, ~S|(kernel/check-source "default" "(return 42)")|)

    assert check.outcome == :valid
    assert %{subordinate_source_checks: 1} = ReplSession.usage(session)
  end

  test "workflow nested-evaluation contention preserves its public reason" do
    {:ok, holder} = Agent.start_link(fn -> nil end)
    test_pid = self()

    {:ok, reserve} =
      Capability.new(
        name: "reserve",
        input_schema: @input_schema,
        callback: fn _arguments ->
          state = Agent.get(holder, & &1)
          callback_pid = self()

          owner =
            spawn_link(fn ->
              {:ok, _memory, _history, lease} =
                RunState.reserve_evaluation(state, "default", :fail_fast)

              send(callback_pid, {:reserved, self(), lease})

              receive do
                :release ->
                  send(test_pid, {:released, self(), RunState.release_evaluation(state, lease)})
              end
            end)

          receive do
            {:reserved, ^owner, lease} ->
              Agent.update(holder, fn _state -> {state, lease, owner} end)
          end

          {:ok, %{}}
        end
      )

    {:ok, component} = Library.component("kernel")
    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [reserve])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-nested-contention")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)
    state = owned_run_state(session)
    Agent.update(holder, fn _unset -> state end)

    result =
      ReplSession.eval(
        session,
        ~S|(do (tool/reserve {}) (tool/kernel-eval {:mission "default" :kind :source :source "(return 42)"}))|
      )

    assert {:error, %{fail: %{reason: :evaluation_in_progress}}, session} = result

    assert ReplSession.open?(session)
    {^state, _lease, owner} = Agent.get(holder, & &1)
    send(owner, :release)
    assert_receive {:released, ^owner, :ok}
    assert {:ok, _events} = ReplSession.close(session)
  end

  test "a yielded workflow lease rejects stale revisions without corrupting continuation" do
    {:ok, state} = RunState.start(Limits.defaults())
    {:ok, _memory, _history, workflow_lease} = RunState.reserve_workflow_evaluation(state)
    assert {:ok, revision} = RunState.yield_workflow_evaluation(state, workflow_lease)

    {:ok, memory, history, newer_workflow_lease} = RunState.reserve_workflow_evaluation(state)
    assert :ok = RunState.commit_evaluation(state, newer_workflow_lease, memory, history)
    assert {:error, :stale} = RunState.resume_workflow_evaluation(state, revision)
    assert :ok = RunState.stop(state)
  end

  test "a stale workflow resume returns a bounded error and closes its event lifecycle" do
    holder = :ets.new(:stale_workflow_resume, [:set, :public])

    {:ok, revise} =
      Capability.new(
        name: "revise",
        input_schema: @input_schema,
        callback: fn _arguments ->
          [{:state, state}] = :ets.lookup(holder, :state)

          :sys.replace_state(state.pid, fn owned ->
            continuation = %{memory: %{}, history: [], revision: 1}
            %{owned | continuations: Map.put(owned.continuations, "$workflow", continuation)}
          end)

          {:ok, %{}}
        end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [revise])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-stale-resume")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)
    [{_id, {owner, token}}] = :ets.lookup(session.access, session.id)
    {:ok, _owned_config, state} = ReplSessionOwner.resources(owner, token)
    true = :ets.insert(holder, {:state, state})

    assert {:error, %{fail: %{reason: :evaluation_in_progress}}, session} =
             ReplSession.eval(session, "(tool/revise {})")

    assert {:ok, events} = ReplSession.close(session)

    assert Enum.map(events, & &1.type) == [
             "run-started",
             "evaluation-started",
             "capability-started",
             "capability-stopped",
             "evaluation-stopped",
             "run-stopped"
           ]
  end

  test "direct evaluations persist definitions and bounded turn history" do
    {:ok, session} = ReplSession.new()
    assert {:ok, first, session} = ReplSession.eval(session, "(def x 40)")
    assert first.memory["x"] == 40
    assert {:ok, second, session} = ReplSession.eval(session, "(+ x 2)")
    assert second.return == 42
    assert {:ok, third, _session} = ReplSession.eval(session, "(+ *1 1)")
    assert third.return == 43

    assert %{history_count: 3, history_bytes: history_bytes} =
             ReplSession.evaluation_memory_summary(session)

    assert history_bytes > 0
  end

  test "direct eval names an unattached shipped library" do
    {:ok, session} = ReplSession.new()

    assert {:ok, doc, session} = ReplSession.eval(session, ~S|(doc "agent.core/run")|)
    assert doc.return == nil

    output = Enum.join(doc.prints, "\n")
    assert output =~ ~s|"agent.core/run" is an export of shipped library "agent.core"|
    assert output =~ "--project PROJECT.json or --manifest MANIFEST.json"

    assert {:ok, apropos, session} = ReplSession.eval(session, ~S|(apropos "agent")|)
    refute "agent.core" in apropos.return
    assert apropos.prints == []

    assert {:ok, unknown, session} = ReplSession.eval(session, ~S|(doc "missing/ns")|)
    assert unknown.prints == [~s(No documentation found for "missing/ns".)]

    assert {:ok, _events} = ReplSession.close(session)
  end

  test "REPL sessions reject JSON-result configurations" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-json-projection")
    on_exit(fn -> if Process.alive?(sink.pid), do: EventSink.stop(sink) end)

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink,
        result_projection: :json
      )

    assert {:error, :invalid_repl_session} = ReplSession.new(config: config)
    assert Process.alive?(sink.pid)
  end

  test "sessions reject evaluation and teardown outside their creating process" do
    {:ok, eval_session} = ReplSession.new()
    refute Enum.any?(Map.values(Map.from_struct(eval_session)), &is_pid/1)
    refute Map.has_key?(eval_session, :pid)
    refute Map.has_key?(eval_session, :token)
    refute Map.has_key?(eval_session, :owner)
    refute Map.has_key?(eval_session, :state)
    refute Map.has_key?(eval_session, :config)
    refute Map.has_key?(eval_session, :memory)
    refute Map.has_key?(eval_session, :history)

    assert :private = :ets.info(eval_session.access, :protection)

    assert {:error, ArgumentError} =
             from_other_process(fn ->
               try do
                 :ets.lookup(eval_session.access, eval_session.id)
               rescue
                 exception -> {:error, exception.__struct__}
               end
             end)

    assert {:error, :session_owner_mismatch} =
             from_other_process(fn -> ReplSession.eval(eval_session, "(def leaked 1)") end)

    assert {:error, %{fail: %{reason: :unbound_var}}, _session} =
             ReplSession.eval(eval_session, "leaked")

    assert %{defined_count: 0} = ReplSession.evaluation_memory_summary(eval_session)

    assert {:ok, _events} = ReplSession.close(eval_session)

    {:ok, close_session} = ReplSession.new()

    malformed = %{close_session | id: make_ref()}

    assert {:error, :session_owner_mismatch} =
             from_other_process(fn -> ReplSession.close(malformed) end)

    assert {:error, :session_owner_mismatch} =
             from_other_process(fn -> ReplSession.close(close_session) end)

    assert {:ok, %{return: 42}, close_session} = ReplSession.eval(close_session, "42")
    assert {:ok, _events} = ReplSession.close(close_session)

    {:ok, abort_session} = ReplSession.new()

    assert {:error, :session_owner_mismatch} =
             from_other_process(fn -> ReplSession.abort(abort_session, :frontend_exit) end)

    assert {:ok, %{return: 42}, abort_session} = ReplSession.eval(abort_session, "42")
    assert {:ok, _events} = ReplSession.abort(abort_session, :frontend_exit)
  end

  test "configured sessions require event and inspection sinks owned by their creator" do
    parent = self()

    config_owner =
      Task.async(fn ->
        {:ok, workflow} = WorkflowEnvironment.new([])
        {:ok, mission} = MissionEnvironment.new([])
        limits = Limits.defaults()
        {:ok, sink} = EventSink.start(:normal, limits, run_id: "foreign-repl-config")

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
                    send(parent, :foreign_config_resource_closed)
                    :ok
                  end
                ],
                limits
              )
          )

        send(parent, {:foreign_config, config})

        receive do
          :stop_sink ->
            EventSink.stop(sink)
            send(parent, :foreign_sink_stopped)
        end

        receive do: (:finish -> :ok)
      end)

    assert_receive {:foreign_config, foreign_config}, 2_000
    foreign_sink_ref = Process.monitor(foreign_config.event_sink.pid)
    assert {:error, :session_owner_mismatch} = ReplSession.new(config: foreign_config)
    assert Process.alive?(foreign_config.event_sink.pid)
    refute_receive :foreign_config_resource_closed

    send(config_owner.pid, :stop_sink)
    assert_receive :foreign_sink_stopped
    assert_receive {:DOWN, ^foreign_sink_ref, :process, _, :normal}, 2_000

    assert {:error, :session_owner_mismatch} = ReplSession.new(config: foreign_config)
    refute_receive :foreign_config_resource_closed

    send(config_owner.pid, :finish)
    assert :ok = Task.await(config_owner)

    inspection_owner =
      Task.async(fn ->
        {:ok, sink} =
          StreamingInspection.start(
            run_id: "foreign-inspection",
            trace_id: "foreign-inspection"
          )

        send(parent, {:foreign_inspection_sink, sink})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:foreign_inspection_sink, foreign_inspection}, 2_000
    inspection_ref = Process.monitor(foreign_inspection.pid)

    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, local_sink} = EventSink.start(:normal, limits, run_id: "local-repl-config")

    {:ok, mixed_config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: local_sink,
        inspection_sink: foreign_inspection
      )

    assert {:error, :session_owner_mismatch} = ReplSession.new(config: mixed_config)
    assert Process.alive?(local_sink.pid)
    assert :ok = EventSink.stop(local_sink)
    send(inspection_owner.pid, :finish)
    assert :ok = Task.await(inspection_owner)
    assert_receive {:DOWN, ^inspection_ref, :process, _, _reason}, 2_000
  end

  # The owned sink is `:sys.suspend`ed, so setup waits the EventSink call
  # budget (~5 s) rather than tearing the config down. `mix nightly`.
  @tag :nightly
  test "a suspended owned sink fails setup without tearing down the config" do
    parent = self()

    task =
      Task.async(fn ->
        {:ok, workflow} = WorkflowEnvironment.new([])
        {:ok, mission} = MissionEnvironment.new([])
        limits = Limits.defaults()
        {:ok, sink} = EventSink.start(:normal, limits, run_id: "suspended-repl-config")

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
                    send(parent, :suspended_config_resource_closed)
                    :ok
                  end
                ],
                limits
              )
          )

        :ok = :sys.suspend(sink.pid)
        result = ReplSession.new(config: config)
        alive? = Process.alive?(sink.pid)
        :ok = :sys.resume(sink.pid)
        :ok = EventSink.stop(sink)
        {result, alive?}
      end)

    assert {{:error, :session_owner_mismatch}, true} = Task.await(task, 7_000)
    assert_receive :suspended_config_resource_closed
  end

  test "setup cleanup remains bounded when one owned sink is dead and the other is suspended" do
    parent = self()

    task =
      Task.async(fn ->
        {:ok, workflow} = WorkflowEnvironment.new([])
        {:ok, mission} = MissionEnvironment.new([])
        limits = Limits.defaults()
        {:ok, event_sink} = EventSink.start(:private, limits, run_id: "mixed-dead-wedged")

        {:ok, inspection_sink} =
          StreamingInspection.start(
            run_id: "mixed-dead-wedged",
            trace_id: "mixed-dead-wedged"
          )

        {:ok, config} =
          RunConfig.new(
            workflow_environment: workflow,
            missions: %{"default" => mission},
            input: %{},
            limits: limits,
            event_sink: event_sink,
            inspection_sink: inspection_sink,
            provider_session:
              ProviderSessionFixture.start(
                [
                  fn ->
                    send(parent, :mixed_config_resource_closed)
                    :ok
                  end
                ],
                limits
              )
          )

        :ok = EventSink.stop(event_sink)
        :ok = :sys.suspend(inspection_sink.pid)
        result = ReplSession.new(config: config)
        {result, Process.alive?(inspection_sink.pid)}
      end)

    assert {{:error, :event_sink_error}, false} = Task.await(task, 3_000)
    assert_receive :mixed_config_resource_closed
  end

  test "setup cleanup remains bounded with a dead inspection sink and suspended event sink" do
    parent = self()

    task =
      Task.async(fn ->
        {:ok, workflow} = WorkflowEnvironment.new([])
        {:ok, mission} = MissionEnvironment.new([])
        limits = Limits.defaults()
        {:ok, event_sink} = EventSink.start(:private, limits, run_id: "wedged-dead-mixed")

        {:ok, inspection_sink} =
          StreamingInspection.start(
            run_id: "wedged-dead-mixed",
            trace_id: "wedged-dead-mixed"
          )

        {:ok, config} =
          RunConfig.new(
            workflow_environment: workflow,
            missions: %{"default" => mission},
            input: %{},
            limits: limits,
            event_sink: event_sink,
            inspection_sink: inspection_sink,
            provider_session:
              ProviderSessionFixture.start(
                [
                  fn ->
                    send(parent, :reverse_mixed_config_resource_closed)
                    :ok
                  end
                ],
                limits
              )
          )

        :ok = InspectionSink.stop(inspection_sink)
        :ok = :sys.suspend(event_sink.pid)
        result = ReplSession.new(config: config)
        {result, Process.alive?(event_sink.pid)}
      end)

    assert {{:error, :inspection_sink_error}, false} = Task.await(task, 3_000)
    assert_receive :reverse_mixed_config_resource_closed
  end

  test "owner exit closes hidden session resources" do
    parent = self()

    creator =
      Task.async(fn ->
        {:ok, workflow} = WorkflowEnvironment.new([])
        {:ok, mission} = MissionEnvironment.new([])
        limits = Limits.defaults()
        {:ok, sink} = EventSink.start(:normal, limits, run_id: "owner-exit-repl")

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
                    send(parent, :owner_exit_resource_closed)
                    :ok
                  end
                ],
                limits
              )
          )

        {:ok, _session} = ReplSession.new(config: config)
        send(parent, {:owner_exit_session, sink.pid, self()})
        receive do: (:finish -> :ok)
        :ok
      end)

    assert_receive {:owner_exit_session, sink_pid, creator_pid}, 2_000
    sink_ref = Process.monitor(sink_pid)
    send(creator_pid, :finish)
    assert :ok = Task.await(creator)
    assert_receive {:DOWN, ^sink_ref, :process, ^sink_pid, :normal}, 2_000
    assert_receive :owner_exit_resource_closed, 2_000
  end

  test "owner exit cancels an in-flight evaluation sandbox" do
    parent = self()

    {creator, creator_ref} =
      spawn_monitor(fn ->
        {:ok, workflow} = WorkflowEnvironment.new([])
        {:ok, mission} = MissionEnvironment.new([])

        {:ok, limits} =
          Limits.new(
            evaluation_timeout_ms: 30_000,
            evaluation_heap_words: 1_250_000,
            run_duration_ms: 30_000
          )

        {:ok, sink} = EventSink.start(:normal, limits, run_id: "owner-exit-evaluation")

        {:ok, config} =
          RunConfig.new(
            workflow_environment: workflow,
            missions: %{"default" => mission},
            input: %{},
            limits: limits,
            event_sink: sink
          )

        {:ok, session} = ReplSession.new(config: config)
        send(parent, {:owner_exit_evaluation_ready, self()})

        receive do
          :evaluate ->
            # A trivial `(loop [x 0] (recur (inc x)))` would race this test's
            # own setup regardless of load -- see `long_running_body/1` for
            # why it is not the infinite loop it looks like. The heavier
            # `repeats: 5` (~30s to reach the cap on its own) is safe here,
            # unlike in RunCoordinatorExecutionTest:
            # `Evaluation.evaluate_with_lease/6` passes `link: true`, so the
            # underlying sandbox process is genuinely torn down when this
            # evaluation's caller dies -- no orphaned-process risk to bound.
            # This still finishes fast, since the test interrupts the
            # evaluation long before that natural completion.
            ReplSession.eval(session, long_running_body(5))
        end
      end)

    # Registered immediately, before any assertion below can fail: killing
    # `creator` is exactly this test's own mechanism for cancelling the
    # evaluation, so this is a safe no-op on the pass path (creator is
    # already dead by then) and, on any earlier failure, stops the ~30s
    # CPU-heavy loop instead of leaving it running unlinked until its own
    # deadline.
    on_exit(fn -> if Process.alive?(creator), do: Process.exit(creator, :kill) end)

    assert_receive {:owner_exit_evaluation_ready, ^creator}, 2_000
    assert {:trap_exit, false} = Process.info(creator, :trap_exit)
    assert 1 = :erlang.trace(creator, true, [:procs])
    send(creator, :evaluate)

    assert_receive {:trace, ^creator, :spawn, compile_worker, _mfa}, 2_000
    compile_ref = Process.monitor(compile_worker)
    assert_receive {:DOWN, ^compile_ref, :process, ^compile_worker, _reason}, 2_000

    assert_receive {:trace, ^creator, :spawn, evaluation_worker, _mfa}, 2_000
    evaluation_ref = Process.monitor(evaluation_worker)
    assert Process.alive?(evaluation_worker)

    on_exit(fn ->
      if Process.alive?(evaluation_worker), do: Process.exit(evaluation_worker, :kill)
    end)

    Process.exit(creator, :shutdown)
    assert_receive {:DOWN, ^creator_ref, :process, ^creator, :shutdown}, 2_000
    assert_receive {:DOWN, ^evaluation_ref, :process, ^evaluation_worker, _reason}, 2_000
  end

  test "REPL session-owner death drains provider work before closing its resource" do
    parent = self()
    provider_table = :ets.new(:repl_owner_death_provider, [:set, :public])

    callback = fn _arguments ->
      true = :ets.insert(provider_table, {:provider, self()})
      send(parent, {:repl_owner_death_provider_started, self()})

      receive do
        :never -> {:ok, %{}}
      end
    end

    {creator, creator_ref} =
      spawn_monitor(fn ->
        {:ok, capability} =
          Capability.new(
            name: "repl_owner_death",
            input_schema: %{"type" => "object", "additionalProperties" => false},
            callback: callback
          )

        {:ok, workflow} = WorkflowEnvironment.new(capabilities: [capability])
        {:ok, mission} = MissionEnvironment.new([])

        {:ok, limits} =
          Limits.new(
            evaluation_timeout_ms: 30_000,
            workflow_timeout_ms: 30_000,
            run_duration_ms: 30_000
          )

        {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-owner-provider")

        close = fn ->
          [{:provider, provider}] = :ets.lookup(provider_table, :provider)
          send(parent, {:repl_owner_death_resource_closed, Process.alive?(provider)})
          :ok
        end

        {:ok, config} =
          RunConfig.new(
            workflow_environment: workflow,
            missions: %{"default" => mission},
            input: %{},
            limits: limits,
            event_sink: sink,
            provider_session: ProviderSessionFixture.start([close], limits)
          )

        {:ok, session} = ReplSession.new(config: config)
        [{_, {session_owner, _token}}] = :ets.lookup(session.access, session.id)
        send(parent, {:repl_session_owner_ready, session_owner})
        ReplSession.eval(session, "(tool/repl_owner_death {})")
      end)

    assert_receive {:repl_session_owner_ready, session_owner}, 5_000
    session_owner_ref = Process.monitor(session_owner)
    assert_receive {:repl_owner_death_provider_started, provider}, 5_000
    Process.exit(session_owner, :kill)

    assert_receive {:DOWN, ^session_owner_ref, :process, ^session_owner, :killed}, 5_000
    assert_receive {:repl_owner_death_resource_closed, false}, 5_000
    refute Process.alive?(provider)
    refute_receive {:repl_owner_death_resource_closed, _alive?}
    assert_receive {:DOWN, ^creator_ref, :process, ^creator, :normal}, 5_000
  end

  test "closing after session-owner death removes the creator access entry" do
    {:ok, close_session} = ReplSession.new()
    [{close_id, {close_owner, close_token}}] = :ets.lookup(close_session.access, close_session.id)
    assert is_reference(close_token)
    close_ref = Process.monitor(close_owner)
    Process.exit(close_owner, :kill)
    assert_receive {:DOWN, ^close_ref, :process, ^close_owner, :killed}, 5_000

    assert {:error, :session_closed} = ReplSession.close(close_session)
    assert :ets.lookup(close_session.access, close_id) == []

    {:ok, abort_session} = ReplSession.new()
    [{abort_id, {abort_owner, abort_token}}] = :ets.lookup(abort_session.access, abort_session.id)
    assert is_reference(abort_token)
    abort_ref = Process.monitor(abort_owner)
    Process.exit(abort_owner, :kill)
    assert_receive {:DOWN, ^abort_ref, :process, ^abort_owner, :killed}, 5_000

    assert :ok = ReplSession.abort(abort_session, :frontend_exit)
    assert :ets.lookup(abort_session.access, abort_id) == []
  end

  test "owner death during resource lookup removes the creator access entry" do
    {:ok, session} = ReplSession.new()
    [{id, {owner, token}}] = :ets.lookup(session.access, session.id)
    :ok = :sys.suspend(owner)
    creator = self()

    {tracer, tracer_ref} =
      spawn_monitor(fn ->
        receive do
          {:trace, ^creator, :send, {:"$gen_call", _from, {^token, :resources}}, ^owner} ->
            Process.exit(owner, :kill)
        end
      end)

    assert 1 = :erlang.trace(creator, true, [:send, {:tracer, tracer}])

    try do
      assert {:error, :session_closed} = ReplSession.close(session)
    after
      assert 1 = :erlang.trace(creator, false, [:send])
    end

    assert_receive {:DOWN, ^tracer_ref, :process, ^tracer, :normal}, 5_000
    assert :ets.lookup(session.access, id) == []
  end

  test "session owner rejects a run state not bound to its configured sinks" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-owner-binding")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, ordinary_state} = RunState.start(limits)

    assert {:error, :session_owner_mismatch} =
             ReplSessionOwner.start(config, ordinary_state, self(), nil)

    :ok = RunState.close(ordinary_state)
    :ok = RunState.stop(ordinary_state)
    :ok = EventSink.stop(sink)
  end

  test "history has a separate ceiling and rejects a candidate continuation atomically" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, limits} =
      Limits.new(evaluation_memory_bytes: 512, evaluation_history_bytes: 128)

    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-history-limit")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)
    assert {:ok, _step, session} = ReplSession.eval(session, "(def retained 42)")
    retained = ReplSession.evaluation_memory_summary(session)

    source = ~s|"#{String.duplicate("x", 512)}"|

    assert {:error, %{fail: %{reason: :history_exceeded}}, session} =
             ReplSession.eval(session, source)

    assert ReplSession.evaluation_memory_summary(session) == retained

    assert {:ok, step, session} = ReplSession.eval(session, "retained")
    assert step.return == 42
    assert %{history_count: 2} = ReplSession.evaluation_memory_summary(session)
  end

  test "failed evaluations roll back continuation memory and emit canonical status" do
    {:ok, session} = ReplSession.new()
    assert {:ok, _step, session} = ReplSession.eval(session, "(def retained 42)")
    assert {:error, _step, session} = ReplSession.eval(session, "(do (def leaked 1) missing)")
    assert {:ok, step, session} = ReplSession.eval(session, "retained")
    assert step.return == 42
    assert {:error, _step, _session} = ReplSession.eval(session, "leaked")
  end

  test "a terminal sink failure cannot hide already committed continuation state" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(normal_event_count: 3)
    {:ok, sink} = EventSink.start(:private, limits, run_id: "repl-commit-sink-failure")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)

    assert {:error, %{fail: %{reason: :limit_exceeded, message: message}}, returned} =
             ReplSession.eval(session, "(def committed 42)")

    assert message =~ "normal_event_count limit 3 was exceeded"

    assert %{attempts: 1, errors: 1} = returned

    assert %{defined_count: 1, history_count: 1} =
             ReplSession.evaluation_memory_summary(returned)

    assert {:error, %{fail: %{reason: :limit_exceeded, message: repeated}}, repeated_session} =
             ReplSession.eval(returned, "committed")

    assert repeated == message
    assert %{attempts: 2, errors: 2} = repeated_session
  end

  test "a private mission session reports a terminal event capture limit" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(normal_event_count: 3)
    {:ok, sink} = EventSink.start(:private, limits, run_id: "mission-event-limit")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    mode = %{kind: :mission, name: "default", component_ids: [], direct_provider_aliases: []}
    {:ok, session} = ReplSession.new(config: config, mode: mode)

    assert {:error, %{fail: %{reason: :limit_exceeded, message: message}}, returned} =
             ReplSession.eval(session, "42")

    assert message =~ "normal_event_count limit 3 was exceeded"
    refute ReplSession.open?(returned)
  end

  test "a failed private mission still reports the terminal event capture limit" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(normal_event_count: 3)
    {:ok, sink} = EventSink.start(:private, limits, run_id: "failed-mission-event-limit")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    mode = %{kind: :mission, name: "default", component_ids: [], direct_provider_aliases: []}
    {:ok, session} = ReplSession.new(config: config, mode: mode)

    assert {:error, %{fail: %{reason: :limit_exceeded, message: message}}, returned} =
             ReplSession.eval(session, "(fail :expected)")

    assert message =~ "normal_event_count limit 3 was exceeded"
    refute ReplSession.open?(returned)
  end

  test "explicit failure rolls back memory and turn history" do
    {:ok, session} = ReplSession.new()
    assert {:ok, _step, session} = ReplSession.eval(session, "(def retained 42)")
    retained = ReplSession.evaluation_memory_summary(session)

    assert {:error, %{fail: %{reason: :explicit_failure}}, session} =
             ReplSession.eval(session, ~s|(do (def leaked 1) (fail "stop"))|)

    assert ReplSession.evaluation_memory_summary(session) == retained
    assert {:ok, %{return: 42}, session} = ReplSession.eval(session, "retained")
    assert {:error, _step, _session} = ReplSession.eval(session, "leaked")
  end

  test "persistent memory is committed only within the Kernel byte ceiling" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(evaluation_memory_bytes: 128)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-memory")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)
    source = ~s|(def oversized "#{String.duplicate("x", 512)}")|

    assert {:error, %{fail: %{reason: :memory_exceeded}}, session} =
             ReplSession.eval(session, source)

    assert {:error, _step, _session} = ReplSession.eval(session, "oversized")
  end

  test "direct code remains bounded by subordinate evaluation ceilings" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 1, workflow_timeout_ms: 5_000)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-timeout")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)

    assert {:error, %{fail: %{reason: reason}}, _session} =
             ReplSession.eval(session, "(loop [x 0] (recur (inc x)))")

    assert reason in [:compile_timeout, :timeout, :loop_limit_exceeded]
  end

  # The interactive path evaluates every form under `evaluation_timeout_ms`.
  # The sandbox reports only the milliseconds it had left when it killed the
  # worker — a number that matches no configured value — so the stopped form
  # has to name the ceiling that bound it and where to raise it.
  test "a form stopped by the evaluation ceiling names the limit and the manifest key" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 200, workflow_timeout_ms: 5_000)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-evaluation-ceiling")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)

    assert {:error, %{fail: %{reason: :timeout, message: message}}, _session} =
             ReplSession.eval(session, long_running_body(4))

    assert RuntimeLimitDiagnostic.timeout_message?(message)
    assert message =~ "evaluation_timeout_ms limit 200 ms was exceeded during execution"
    assert message =~ "raise limits.evaluation_timeout_ms in the manifest"
  end

  # A parallel deadline surfaces as an ordinary `:timeout` too. Answering it
  # with the evaluation ceiling would name a limit that never fired, so the
  # stable parallel message picks `parallel_timeout_ms` out of the family.
  test "a parallel operation stopped by its own deadline names parallel_timeout_ms" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, limits} =
      Limits.new(
        parallel_timeout_ms: 50,
        evaluation_timeout_ms: 5_000,
        workflow_timeout_ms: 10_000
      )

    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-parallel-ceiling")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)

    assert {:error, %{fail: %{reason: :timeout, message: message}}, _session} =
             ReplSession.eval(session, "(pmap (fn [_x] #{long_running_body(4)}) [1])")

    assert RuntimeLimitDiagnostic.timeout_message?(message)
    assert message =~ "parallel_timeout_ms limit 50 ms was exceeded during execution"
    assert message =~ "raise limits.parallel_timeout_ms in the manifest"
  end

  # A form that never finishes compiling reports its own reason, and the same
  # ceiling bounds it. The phase is taken from that reason, the way `ptc run`
  # takes it, so a compile stop is not reported as an execution stop.
  test "a form stopped while compiling names the same ceiling and the compilation phase" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 1, workflow_timeout_ms: 5_000)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-compilation-ceiling")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)
    source = "(do " <> String.duplicate("(+ 1 2) ", 14_000) <> ")"

    assert {:error, %{fail: %{reason: :compile_timeout, message: message}}, _session} =
             ReplSession.eval(session, source)

    assert RuntimeLimitDiagnostic.timeout_message?(message)
    assert message =~ "evaluation_timeout_ms limit 1 ms was exceeded during compilation"
    assert message =~ "raise limits.evaluation_timeout_ms in the manifest"
  end

  test "session-wide evaluation exhaustion is exact and terminal" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(subordinate_evaluations: 1)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-session-limit")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)
    assert {:ok, _step, session} = ReplSession.eval(session, "(def retained 41)")

    assert {:error,
            %{
              fail: %{reason: :limit_exceeded, message: message},
              memory: memory
            }, session} =
             ReplSession.eval(session, "42")

    assert memory["retained"] == 41
    assert message =~ "subordinate_evaluations limit 1 was exceeded"
    refute message =~ "manifest"
    refute ReplSession.open?(session)

    assert {:ok, events} = ReplSession.close(session)

    assert %{type: "limit-exceeded", data: %{reason: :subordinate_evaluations}} =
             Enum.find(events, &(&1.type == "limit-exceeded"))

    assert List.last(events).data.reason == :subordinate_evaluations
  end

  test "the direct interactive profile preserves definitions and exact history past 128 forms" do
    {:ok, session} = ReplSession.new_interactive()
    assert {:ok, _step, session} = ReplSession.eval(session, "(def retained 40)")

    session =
      Enum.reduce(1..129, session, fn value, current ->
        assert {:ok, %{return: ^value}, next} =
                 ReplSession.eval(current, Integer.to_string(value))

        next
      end)

    assert {:ok, %{return: [129, 128, 127, 40]}, session} =
             ReplSession.eval(session, "[*1 *2 *3 retained]")

    assert {:ok, _events} = ReplSession.close(session)
  end

  test "the owner closes provider resources when the absolute deadline expires at the prompt" do
    parent = self()
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(run_duration_ms: 50)
    {:ok, sink} = EventSink.start(:normal, limits)

    close = fn ->
      send(parent, :deadline_provider_closed)
      :ok
    end

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink,
        provider_session: ProviderSessionFixture.start([close], limits)
      )

    {:ok, session} = ReplSession.new(config: config)

    assert_receive :deadline_provider_closed, 1_000
    refute_receive :deadline_provider_closed
    assert ReplSession.terminal?(session)

    assert {:error, %{fail: %{reason: :limit_exceeded, message: message}}, session} =
             ReplSession.eval(session, "42")

    assert message =~ "run_duration_ms limit 50 ms was exceeded"
    assert {:ok, events} = ReplSession.close(session)
    assert List.last(events).data.reason == :deadline_expired
  end

  test "close records an elapsed deadline before cancelling its pending timer" do
    {:ok, session} = ReplSession.new()
    state = owned_run_state(session)

    :sys.replace_state(state.pid, fn run_state ->
      %{run_state | deadline_ms: System.monotonic_time(:millisecond) - 1}
    end)

    assert {:ok, events} = ReplSession.close(session)

    assert [%{data: %{reason: :deadline_expired}}] =
             Enum.filter(events, &(&1.type == "limit-exceeded"))

    assert List.last(events).data.reason == :deadline_expired
  end

  test "a form that consumes the absolute deadline terminalizes before the owner timer runs" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, limits} =
      Limits.new(
        run_duration_ms: 200,
        evaluation_timeout_ms: 5_000,
        workflow_timeout_ms: 5_000
      )

    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-in-flight-deadline")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)
    owner = owned_owner(session)

    :sys.replace_state(owner, fn state ->
      Process.cancel_timer(state.deadline_timer)
      %{state | deadline_timer: nil, deadline_token: nil}
    end)

    assert {:error, %{fail: %{reason: :limit_exceeded, message: message}}, session} =
             ReplSession.eval(session, long_running_body(4))

    assert message =~ "run_duration_ms limit 200 ms was exceeded"
    assert ReplSession.terminal?(session)
    assert {:ok, events} = ReplSession.close(session)

    assert [%{data: %{reason: :deadline_expired}}] =
             Enum.filter(events, &(&1.type == "limit-exceeded"))

    assert List.last(events).data.reason == :deadline_expired
  end

  @tag :nightly
  test "resource lookup waits through provider cleanup beyond the default call timeout" do
    parent = self()
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, limits} =
      Limits.new(run_duration_ms: 50, provider_cleanup_timeout_ms: 6_000)

    {:ok, sink} = EventSink.start(:normal, limits)

    close = fn ->
      send(parent, {:slow_deadline_cleanup_started, self()})

      receive do
        :finish_slow_deadline_cleanup -> :ok
      end
    end

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink,
        provider_session: ProviderSessionFixture.start([close], limits)
      )

    {:ok, session} = ReplSession.new(config: config)
    assert_receive {:slow_deadline_cleanup_started, cleanup_worker}, 1_000
    Process.send_after(cleanup_worker, :finish_slow_deadline_cleanup, 5_100)

    assert {:error, %{fail: %{reason: :limit_exceeded}}} =
             ReplSession.terminal_error(session)

    assert {:ok, events} = ReplSession.close(session)
    assert List.last(events).data.reason == :deadline_expired
  end

  @tag :tmp_dir
  test "owner death preserves an already-recorded deadline in the trace", %{tmp_dir: directory} do
    parent = self()
    trace_path = Path.join(directory, "deadline-owner-death.jsonl")

    {creator, creator_ref} =
      spawn_monitor(fn ->
        {:ok, workflow} = WorkflowEnvironment.new([])
        {:ok, mission} = MissionEnvironment.new([])
        {:ok, limits} = Limits.new(run_duration_ms: 50)
        {:ok, sink} = EventSink.start(:normal, limits)

        close = fn ->
          send(parent, :owner_death_deadline_provider_closed)
          :ok
        end

        {:ok, config} =
          RunConfig.new(
            workflow_environment: workflow,
            missions: %{"default" => mission},
            input: %{},
            limits: limits,
            event_sink: sink,
            provider_session: ProviderSessionFixture.start([close], limits)
          )

        {:ok, session} = ReplSession.new(config: config, trace_path: trace_path)
        [{_, {owner, _token}}] = :ets.lookup(session.access, session.id)
        send(parent, {:owner_death_deadline_ready, owner})

        receive do
          :disconnect -> :ok
        end
      end)

    assert_receive {:owner_death_deadline_ready, owner}, 1_000
    owner_ref = Process.monitor(owner)
    assert_receive :owner_death_deadline_provider_closed, 1_000
    send(creator, :disconnect)
    assert_receive {:DOWN, ^creator_ref, :process, ^creator, :normal}, 1_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 5_000

    trace = File.read!(trace_path)
    assert trace =~ "deadline_expired"
    refute trace =~ "session_owner_failed"
  end

  test "a direct session limit diagnostic does not prescribe a nonexistent manifest" do
    {:ok, session} = ReplSession.new()
    %{subordinate_evaluations: limit} = owned_limits(session)

    state = owned_run_state(session)
    :sys.replace_state(state.pid, &%{&1 | evaluations: limit})

    assert {:error, %{fail: %{reason: :limit_exceeded, message: message}}, session} =
             ReplSession.eval(session, "42")

    assert message =~ "subordinate_evaluations limit #{limit} was exceeded"
    refute message =~ "manifest"
    refute ReplSession.open?(session)
    assert {:ok, _events} = ReplSession.close(session)
  end

  test "deadline, busy, and closed reservations preserve distinct public results" do
    {:ok, busy_session} = ReplSession.new()
    busy_state = owned_run_state(busy_session)
    assert {:ok, _memory, _history, lease} = RunState.reserve_workflow_evaluation(busy_state)

    assert {:error,
            %{fail: %{reason: :evaluation_in_progress, message: "REPL evaluation in progress"}},
            busy_session} = ReplSession.eval(busy_session, "42")

    assert ReplSession.open?(busy_session)
    assert :ok = RunState.release_evaluation(busy_state, lease)
    assert {:ok, %{return: 42}, busy_session} = ReplSession.eval(busy_session, "42")
    assert {:ok, busy_events} = ReplSession.close(busy_session)
    refute Enum.any?(busy_events, &(&1.type == "limit-exceeded"))

    {:ok, deadline_session} = ReplSession.new()
    deadline_state = owned_run_state(deadline_session)

    :sys.replace_state(deadline_state.pid, fn state ->
      %{state | deadline_ms: System.monotonic_time(:millisecond) - 1}
    end)

    assert {:error, %{fail: %{reason: :limit_exceeded, message: deadline_message}},
            deadline_session} = ReplSession.eval(deadline_session, "42")

    assert deadline_message =~ "run_duration_ms limit 30000 ms was exceeded"
    refute deadline_message =~ "manifest"
    refute ReplSession.open?(deadline_session)
    assert {:ok, deadline_events} = ReplSession.close(deadline_session)

    assert %{type: "limit-exceeded", data: %{reason: :deadline_expired}} =
             Enum.find(deadline_events, &(&1.type == "limit-exceeded"))

    assert List.last(deadline_events).data.reason == :deadline_expired

    {:ok, closed_session} = ReplSession.new()
    closed_state = owned_run_state(closed_session)
    assert :ok = RunState.close(closed_state)

    assert {:error, %{fail: %{reason: :session_closed, message: "REPL session is closed"}},
            closed_session} = ReplSession.eval(closed_session, "42")

    refute ReplSession.open?(closed_session)
    assert {:ok, closed_events} = ReplSession.close(closed_session)

    assert %{type: "limit-exceeded", data: %{reason: :run_closed}} =
             Enum.find(closed_events, &(&1.type == "limit-exceeded"))

    assert List.last(closed_events).data.reason == :run_closed
  end

  test "closed and constructor-failed sessions leave no live sink" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "closed-repl")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)
    sink_pid = sink.pid
    ref = Process.monitor(sink_pid)
    assert {:ok, _events} = ReplSession.close(session)
    assert_receive {:DOWN, ^ref, :process, ^sink_pid, :normal}
    assert :ets.lookup(session.access, session.id) == []

    assert {:error, %{fail: %{reason: :session_closed}}, ^session} =
             ReplSession.eval(session, "42")

    assert {:error, :session_closed} = ReplSession.close(session)

    {:ok, replacement} = ReplSession.new()
    assert replacement.access == session.access
    assert {:ok, _events} = ReplSession.close(replacement)

    # Build-time validation now rejects a payload the configured sink could
    # not accept, so the runtime constructor failure is triggered by a full
    # sink instead of an oversized payload.
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(normal_event_count: 3)
    {:ok, private_sink} = EventSink.start(:private, limits, run_id: "repl-constructor")
    failed_pid = private_sink.pid
    failed_ref = Process.monitor(failed_pid)

    for _index <- 1..2 do
      :ok = EventSink.emit(private_sink, "run-started", %{missions: %{}})
    end

    assert {:error, :invalid_run_config} =
             RunConfig.new(
               workflow_environment: workflow,
               missions: %{"default" => mission},
               input: %{},
               limits: limits,
               event_sink: private_sink
             )

    EventSink.stop(private_sink)
    assert_receive {:DOWN, ^failed_ref, :process, ^failed_pid, :normal}
  end

  test "a rejected reused config cannot tear down the live session" do
    parent = self()
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-one-shot-owner")

    {:ok, config} =
      config_with_close_message(workflow, mission, limits, sink, parent, :resource_closed)

    {:ok, session} = ReplSession.new(config: config)
    assert {:error, :event_sink_error} = ReplSession.new(config: config)
    refute_receive :resource_closed
    assert Process.alive?(sink.pid)

    assert {:ok, %{return: 42}, session} = ReplSession.eval(session, "42")
    assert {:ok, _events} = ReplSession.close(session)
    assert_receive :resource_closed
  end

  test "a distinct config rejected by a live session closes only its resources" do
    parent = self()
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-distinct-owner")

    config = fn close_message ->
      config_with_close_message(workflow, mission, limits, sink, parent, close_message)
    end

    {:ok, winner_config} = config.(:winner_resource_closed)
    {:ok, loser_config} = config.(:loser_resource_closed)

    {:ok, session} = ReplSession.new(config: winner_config)
    assert {:error, :event_sink_error} = ReplSession.new(config: loser_config)
    assert_receive :loser_resource_closed
    refute_receive :winner_resource_closed

    assert {:ok, %{return: 42}, session} = ReplSession.eval(session, "42")
    assert {:ok, _events} = ReplSession.close(session)
    assert_receive :winner_resource_closed
  end

  # ex_dna:disable-for-next-line — mirrors the Kernel owner-resource fixture for REPL coverage
  defp config_with_close_message(workflow, mission, limits, sink, parent, close_message) do
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

  test "configuration assembly rejects a run-started payload above the event ceiling" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(event_payload_bytes: EventBudget.minimum_normal_payload_bytes())
    connector_snapshots = [%{"value" => String.duplicate("x", 10_000)}]
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-metadata-ceiling")

    assert {:error, :run_started_metadata_exceeded} =
             RunConfig.new(
               workflow_environment: workflow,
               missions: %{"default" => mission},
               input: %{},
               limits: limits,
               event_sink: sink,
               connector_snapshots: connector_snapshots
             )

    {:ok, private_sink} = EventSink.start(:private, limits, run_id: "repl-private-ceiling")

    assert {:error, :run_started_metadata_exceeded} =
             RunConfig.new(
               workflow_environment: workflow,
               missions: %{"default" => mission},
               input: %{},
               limits: limits,
               event_sink: private_sink,
               connector_snapshots: connector_snapshots
             )

    EventSink.stop(sink)
    EventSink.stop(private_sink)
  end

  test "abort derives error usage even when the caller holds the original session value" do
    {:ok, original} = ReplSession.new()
    assert {:error, _step, _updated} = ReplSession.eval(original, "missing")
    assert {:ok, events} = ReplSession.abort(original, :frontend_exception)
    stopped = List.last(events)
    assert stopped.type == "run-stopped"
    assert stopped.data.usage.errors == 1
  end

  test "terminal admission bounds caller-held REPL counters" do
    {:ok, session} = ReplSession.new()
    oversized = Bitwise.bsl(1, 2_200_000)
    forged = %{session | attempts: oversized, errors: oversized}

    assert {:ok, events} = ReplSession.close(forged)
    stopped = List.last(events)

    assert stopped.data.outcome == :error
    assert stopped.data.reason == :repl_evaluation_error
    assert stopped.data.usage.errors == 4_294_967_295
  end

  test "close atomically returns a reserved terminal batch and exact drop usage" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, limits} =
      Limits.new(
        normal_event_count: 4,
        normal_event_bytes: 100_000,
        event_payload_bytes: 10_000
      )

    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-terminal-reserve")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)
    assert {:ok, %{return: 42}, session} = ReplSession.eval(session, "42")
    assert {:ok, events} = ReplSession.close(session)

    assert Enum.map(events, & &1.type) ==
             ["run-started", "evaluation-started", "events-dropped", "run-stopped"]

    assert List.last(events).data.usage.events_dropped == %{"evaluation-stopped" => 1}
  end

  test "configured workflow capabilities use the bounded dispatcher and canonical events" do
    {:ok, echo} =
      Capability.new(
        name: "echo",
        input_schema: @input_schema,
        callback: fn args -> {:ok, args} end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [echo])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-capability")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)
    assert {:ok, step, session} = ReplSession.eval(session, "(tool/echo {\"value\" 42})")
    assert step.return == %{status: :ok, value: %{"value" => 42}}
    assert {:ok, events} = ReplSession.close(session)

    assert [
             "run-started",
             "evaluation-started",
             "capability-started",
             "capability-stopped",
             "evaluation-stopped",
             "run-stopped"
           ] == Enum.map(events, & &1.type)
  end

  test "evaluation results do not expose callable continuation authority" do
    {:ok, echo} =
      Capability.new(
        name: "echo",
        input_schema: @input_schema,
        callback: fn args -> {:ok, args} end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [echo])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-result-boundary")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)

    assert {:ok, first, session} = ReplSession.eval(session, "(def saved tool/echo)")
    refute Map.has_key?(first.memory, "saved")

    assert {:ok, second, session} =
             ReplSession.eval(session, ~S|(saved {"value" 42})|)

    assert second.return == %{status: :ok, value: %{"value" => 42}}

    assert {:ok, third, session} = ReplSession.eval(session, "tool/echo")
    assert third.return == "tool/echo"
    assert {:ok, _events} = ReplSession.close(session)
  end

  test "public projection failure rolls back continuation and records an error" do
    {:ok, session} = ReplSession.new()
    assert {:ok, _step, session} = ReplSession.eval(session, "(def retained 42)")

    source =
      ~S|(do (def leaked 1) {(Integer/parseInt "1") :int (Long/parseLong "1") :long})|

    assert {:error, %{fail: %{reason: :java_projection_error}, memory: memory}, session} =
             ReplSession.eval(session, source)

    assert memory["retained"] == 42
    refute Map.has_key?(memory, "leaked")

    assert %{defined_count: 1, history_count: 1} =
             ReplSession.evaluation_memory_summary(session)

    assert {:error, %{fail: %{reason: :unbound_var}}, session} =
             ReplSession.eval(session, "leaked")

    assert {:ok, events} = ReplSession.close(session)

    assert Enum.any?(events, fn event ->
             event.type == "evaluation-stopped" and
               event.data.status == :error and
               event.data.reason == :java_projection_error
           end)

    assert List.last(events).data.outcome == :error
  end

  test "ambiguous capability arguments are counted without REPL provider dispatch" do
    parent = self()

    {:ok, capability} =
      Capability.new(
        name: "capture",
        input_schema: @input_schema,
        callback: fn arguments ->
          send(parent, {:repl_provider_called, arguments})
          {:ok, true}
        end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, mission} = MissionEnvironment.new([])
    limits = Limits.defaults()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-ambiguous")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)

    assert {:ok, %{return: %{kind: :protocol_error, reason: :ambiguous_arguments}}, session} =
             ReplSession.eval(session, ~S|(tool/capture {"path" "a" :path "b"})|)

    assert %{protocol_errors: 1} = ReplSession.usage(session)
    refute_receive {:repl_provider_called, _arguments}
  end

  defp from_other_process(fun) do
    fun
    |> Task.async()
    |> Task.await()
  end

  defp owned_limits(session) do
    {config, _state} = owned_resources(session)
    config.limits
  end

  defp owned_run_state(session) do
    {_config, state} = owned_resources(session)
    state
  end

  defp owned_owner(%ReplSession{access: access, id: id}) do
    [{^id, {owner, _token}}] = :ets.lookup(access, id)
    owner
  end

  defp owned_resources(%ReplSession{access: access, id: id}) do
    [{^id, {owner, token}}] = :ets.lookup(access, id)
    assert {:ok, config, state} = ReplSessionOwner.resources(owner, token)
    {config, state}
  end
end
