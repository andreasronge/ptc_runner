defmodule PtcRunner.Kernel.LoopIterationsLimitTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment

  @loop_1500 "(loop [i 0] (if (< i 1500) (recur (inc i)) i))"
  @sequential_600 """
  (do
    (loop [i 0] (if (< i 600) (recur (inc i)) i))
    (loop [i 0] (if (< i 600) (recur (inc i)) i)))
  """

  test "workflow evaluation inherits a configured workflow_loop_iterations bound" do
    {:ok, config} = workflow_config(workflow_loop_iterations: 1000)

    assert {:error, %{reason: :loop_limit_exceeded}} =
             Kernel.run("(return #{@loop_1500})", config)
  end

  test "workflow evaluation is unbounded when workflow_loop_iterations is omitted" do
    {:ok, config} = workflow_config([])

    assert {:ok, %{value: 1500}} = Kernel.run("(return #{@loop_1500})", config)
  end

  test "subordinate evaluation inherits a configured evaluation_loop_iterations bound" do
    {:ok, limits} = Limits.new(evaluation_loop_iterations: 1000)
    {:ok, state} = RunState.start(limits)
    {:ok, mission} = MissionEnvironment.new([])

    assert %{outcome: :evaluation_error, kind: :loop_limit_exceeded} =
             Evaluation.evaluate_source(state, "default", mission, @loop_1500, 5_000)
  end

  test "subordinate sequential loops pass under an activation-local evaluation bound" do
    {:ok, limits} = Limits.new(evaluation_loop_iterations: 1000)
    {:ok, state} = RunState.start(limits)
    {:ok, mission} = MissionEnvironment.new([])

    assert %{outcome: :continued, value: 600} =
             Evaluation.evaluate_source(state, "default", mission, @sequential_600, 5_000)
  end

  test "REPL evaluation inherits a configured evaluation_loop_iterations bound" do
    {:ok, session} = repl_session(evaluation_loop_iterations: 1000)

    assert {:error, %{fail: %{reason: :loop_limit_exceeded}}, _session} =
             ReplSession.eval(session, @loop_1500)
  end

  test "REPL evaluation is unbounded when evaluation_loop_iterations is omitted" do
    {:ok, session} = repl_session([])

    assert {:ok, %{return: 1500}, _session} = ReplSession.eval(session, @loop_1500)
  end

  defp workflow_config(limit_overrides) do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(limit_overrides)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "loop-iterations-workflow")

    RunConfig.new(
      workflow_environment: workflow,
      missions: %{"default" => mission},
      input: %{},
      limits: limits,
      event_sink: sink
    )
  end

  defp repl_session(limit_overrides) do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(limit_overrides)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "loop-iterations-repl")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    ReplSession.new(config: config)
  end
end
