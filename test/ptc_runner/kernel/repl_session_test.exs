defmodule PtcRunner.Kernel.ReplSessionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  test "direct evaluations persist definitions and bounded turn history" do
    {:ok, session} = ReplSession.new()
    assert {:ok, first, session} = ReplSession.eval(session, "(def x 40)")
    assert first.memory["x"] == 40
    assert {:ok, second, session} = ReplSession.eval(session, "(+ x 2)")
    assert second.return == 42
    assert {:ok, third, _session} = ReplSession.eval(session, "(+ *1 1)")
    assert third.return == 43
  end

  test "failed evaluations roll back continuation memory and emit canonical status" do
    {:ok, session} = ReplSession.new()
    assert {:ok, _step, session} = ReplSession.eval(session, "(def retained 42)")
    assert {:error, _step, session} = ReplSession.eval(session, "(do (def leaked 1) missing)")
    assert {:ok, step, session} = ReplSession.eval(session, "retained")
    assert step.return == 42
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
        mission_environment: mission,
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
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)

    assert {:error, %{fail: %{reason: reason}}, _session} =
             ReplSession.eval(session, "(loop [x 0] (recur (inc x)))")

    assert reason in [:compile_timeout, :timeout, :loop_limit_exceeded]
  end

  test "session-wide evaluation limits do not reset between expressions" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(subordinate_evaluations: 1)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-session-limit")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, session} = ReplSession.new(config: config)
    assert {:ok, _step, session} = ReplSession.eval(session, "41")

    assert {:error, %{fail: %{reason: :limit_exceeded}}, _session} =
             ReplSession.eval(session, "42")
  end

  test "closed and constructor-failed sessions leave no live sink" do
    {:ok, session} = ReplSession.new()
    sink_pid = session.config.event_sink.pid
    ref = Process.monitor(sink_pid)
    assert {:ok, _events} = ReplSession.close(session)
    assert_receive {:DOWN, ^ref, :process, ^sink_pid, :normal}

    assert {:error, %{fail: %{reason: :session_closed}}, ^session} =
             ReplSession.eval(session, "42")

    assert {:error, :session_closed} = ReplSession.close(session)

    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(event_payload_bytes: 1)
    {:ok, private_sink} = EventSink.start(:private, limits, run_id: "repl-constructor")
    failed_pid = private_sink.pid
    failed_ref = Process.monitor(failed_pid)

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: private_sink
      )

    assert {:error, :event_sink_error} = ReplSession.new(config: config)
    assert_receive {:DOWN, ^failed_ref, :process, ^failed_pid, :normal}
  end

  test "abort derives error usage even when the caller holds the original session value" do
    {:ok, original} = ReplSession.new()
    assert {:error, _step, _updated} = ReplSession.eval(original, "missing")
    assert {:ok, events} = ReplSession.abort(original, :frontend_exception)
    stopped = List.last(events)
    assert stopped.type == "run-stopped"
    assert stopped.data.usage.errors == 1
  end

  test "configured workflow capabilities use the bounded dispatcher and canonical events" do
    {:ok, echo} = Capability.new(name: "echo", callback: fn args -> {:ok, args} end)
    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [echo])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "repl-capability")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
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
end
