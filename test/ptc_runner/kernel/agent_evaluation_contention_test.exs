defmodule PtcRunner.Kernel.AgentEvaluationContentionTest do
  @moduledoc """
  The agent loop must not treat a refused subordinate evaluation as a
  correctable model-program error.

  `RunState.reserve_evaluation/1` refuses admission when another evaluation
  holds the run's single lease (`:busy`) or when the run has spent its
  `subordinate_evaluations` budget (`:limit_exceeded`). Neither is anything the
  model wrote, so neither may be fed back as feedback or spend a turn.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp.Eval.Context, as: LispContext

  test "an exhausted evaluation budget fails the workflow instead of spending another turn" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    requester = fn _request ->
      Agent.update(counter, &(&1 + 1))

      {:ok,
       %{
         content: nil,
         tool_calls: [
           %{id: "c1", name: "run_ptc_lisp", args: %{"program" => "(return 42)"}}
         ]
       }}
    end

    {:ok, config, sink} = build_config(requester, [], subordinate_evaluations: 1)

    # The workflow spends the run's only subordinate evaluation before the agent
    # starts, so the agent's first `kernel/eval-source` is refused admission.
    source = ~S"""
    (do
      (kernel/eval-source "(return 1)")
      (return (agent.core/run-value "task" {"max_turns" 4})))
    """

    assert {:error, error} = Kernel.run(source, config)

    assert error.kind == :workflow_failed
    assert error.reason == :explicit_failure

    assert error.details[:failure_kind] == "evaluation-unavailable",
           "expected a typed host failure, got #{inspect(error.details)}"

    assert Agent.get(counter, & &1) == 1,
           "contention must not spend another model call"

    refute Enum.any?(EventSink.events(sink), fn event ->
             event.type == "workflow-annotation" and event.data[:data]["turn"] == 1
           end),
           "contention must not open a second agent turn"
  end

  test "four concurrent agent loops do not retry against a held evaluation lease" do
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    expected_requests = min(4, LispContext.default_pmap_max_concurrency())
    barrier = start_barrier(expected_requests)

    requester = fn _request ->
      request_number = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)
      send(parent, {:agent_request, request_number})
      await_barrier(barrier)

      {:ok,
       %{
         content: nil,
         tool_calls: [
           %{
             id: "c1",
             name: "run_ptc_lisp",
             args: %{"program" => "(return (tool/hold {}))"}
           }
         ]
       }}
    end

    # Whichever branch wins the single evaluation lease parks inside this
    # mission capability, so the other three deterministically meet `:busy`.
    # It is released by run teardown, not by a timer.
    {:ok, hold} =
      Capability.new(
        name: "hold",
        description: "Holds the evaluation lease until the run tears down.",
        input_schema: %{"type" => "object"},
        callback: fn _args ->
          receive do
            :release -> {:ok, %{"held" => true}}
          after
            30_000 -> {:error, :hold_never_released}
          end
        end
      )

    {:ok, config, _sink} = build_config(requester, [hold], [])

    source = ~S"""
    (return
      (pcalls
        #(agent.core/run-value "task 1" {"max_turns" 2})
        #(agent.core/run-value "task 2" {"max_turns" 2})
        #(agent.core/run-value "task 3" {"max_turns" 2})
        #(agent.core/run-value "task 4" {"max_turns" 2})))
    """

    assert {:error, error} = Kernel.run(source, config)
    assert error.kind == :workflow_failed
    assert error.reason == :pcalls_error
    assert error.details[:failure_kind] == "evaluation-unavailable"

    assert Agent.get(counter, & &1) == expected_requests,
           "each started agent must ask once and contention must not buy another request"

    for request_number <- 1..expected_requests do
      assert_received {:agent_request, ^request_number}
    end

    unexpected_request = expected_requests + 1
    refute_received {:agent_request, ^unexpected_request}
  end

  defp start_barrier(expected) do
    spawn_link(fn -> collect_barrier_waiters(expected, []) end)
  end

  defp collect_barrier_waiters(0, waiters) do
    Enum.each(waiters, fn {caller, ref} -> send(caller, {:barrier_released, ref}) end)
  end

  defp collect_barrier_waiters(remaining, waiters) do
    receive do
      {:barrier_arrive, caller, ref} ->
        collect_barrier_waiters(remaining - 1, [{caller, ref} | waiters])
    end
  end

  defp await_barrier(barrier) do
    ref = make_ref()
    send(barrier, {:barrier_arrive, self(), ref})

    receive do
      {:barrier_released, ^ref} -> :ok
    end
  end

  defp build_config(requester, mission_capabilities, limit_overrides) do
    {:ok, llm} = LLMCapability.new(requester: requester)

    names =
      ~w(agent.core agent.feedback agent.native agent.prompt agent.retry
         kernel llm result workflow.event)

    {:ok, components} = Library.components(names)
    {:ok, bundle} = Kernel.compile_bundle(components)
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [llm])
    {:ok, mission} = MissionEnvironment.new(capabilities: mission_capabilities)

    limit_overrides =
      limit_overrides
      |> Keyword.put_new(:evaluation_timeout_ms, 5_000)
      |> Keyword.put_new(:run_duration_ms, 60_000)

    {:ok, limits} = Limits.new(limit_overrides)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "agent-contention")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {:ok, config, sink}
  end
end
