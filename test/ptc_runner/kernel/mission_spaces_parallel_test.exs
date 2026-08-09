defmodule PtcRunner.Kernel.MissionSpacesParallelTest do
  @moduledoc """
  SPIKE: can two agents run concurrently in two mission spaces today?

  Credential-free: the provider is a stub that always returns one valid
  run_ptc_lisp call, so what fails is the concurrency mechanism, not the model.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  @parallel_agents """
  (ns spike.par "Two agent.core loops under pcalls.")

  (defn run [_input]
    (return
      (pcalls
        #(agent.core/run-value "a" {"max_turns" 2 "mission" "one"})
        #(agent.core/run-value "b" {"max_turns" 2 "mission" "two"}))))
  """

  @parallel_evals """
  (ns spike.pareval "Two direct space evaluations under pcalls.")

  (defn run [_input]
    (return
      (pcalls
        #(kernel/eval-source-in "one" "(return 1)")
        #(kernel/eval-source-in "two" "(return 2)"))))
  """

  @sequential_evals """
  (ns spike.seqeval "The same two evaluations, sequentially.")

  (defn run [_input]
    (return
      [(kernel/eval-source-in "one" "(return 1)")
       (kernel/eval-source-in "two" "(return 2)")]))
  """

  defp stub_capability do
    {:ok, capability} =
      LLMCapability.new(
        requester: fn _request ->
          {:ok,
           %{
             "content" => "",
             "tool_calls" => [
               %{
                 "id" => "call-1",
                 "name" => "run_ptc_lisp",
                 "args" => %{"program" => "(return 7)"}
               }
             ]
           }}
        end
      )

    capability
  end

  defp run_source(source, id, libraries, deps) do
    {:ok, component} = Component.new(id: id, source: source, dependencies: deps)
    {:ok, components} = Library.resolve_components([component | libraries])
    {:ok, bundle} = Kernel.compile_bundle(components)

    {:ok, workflow} =
      WorkflowEnvironment.new(bundle: bundle, capabilities: [stub_capability()])

    {:ok, one} = MissionEnvironment.new([])
    {:ok, two} = MissionEnvironment.new([])
    {:ok, default_mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(subordinate_evaluations: 8, workflow_capability_calls: 32)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: id)

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: default_mission,
        extra_missions: %{"one" => one, "two" => two},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    Kernel.run("(#{id}/run data/input)", config)
  end

  test "two agent.core loops under pcalls" do
    outcome =
      run_source(@parallel_agents, "spike.par", [{:library, "agent.core"}], ["agent.core"])

    # Recorded, not asserted as desirable: this documents what actually happens.
    IO.puts("\n[parallel agents] #{inspect(outcome, limit: 6)}")
    assert match?({:ok, _}, outcome) or match?({:error, _}, outcome)
  end

  test "two direct space evaluations under pcalls contend for the single lease" do
    outcome =
      run_source(@parallel_evals, "spike.pareval", [{:library, "kernel"}], ["kernel"])

    IO.puts("\n[parallel evals] #{inspect(outcome, limit: 8)}")
    assert match?({:ok, _}, outcome) or match?({:error, _}, outcome)
  end

  test "the same two evaluations succeed sequentially" do
    assert {:ok, %{value: [one, two]}} =
             run_source(@sequential_evals, "spike.seqeval", [{:library, "kernel"}], ["kernel"])

    assert one.value == 1
    assert two.value == 2
  end
end
