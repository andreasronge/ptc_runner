defmodule PtcRunner.Kernel.ParallelTimeoutLimitTest do
  @moduledoc """
  The `parallel_timeout_ms` limit reaches workflow `pmap`/`pcalls`.

  Before this limit existed, the parallel deadline was a hard-coded 5 s that
  no manifest or host document could reach — two live agents already measured
  4.1 s against it (#1236). One test pins that narrowing works; the nightly
  one proves the old 5 s ceiling is actually gone end to end.
  """
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers, only: [long_running_body: 1]

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  defp park_config(park_ms, limit_overrides) do
    {:ok, park} =
      Capability.new(
        name: "park",
        description: "Parks the calling worker for a bounded interval.",
        input_schema: %{"type" => "object"},
        callback: fn _args ->
          receive do
            :never -> {:ok, %{}}
          after
            park_ms -> {:ok, %{"parked_ms" => park_ms}}
          end
        end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [park])
    {:ok, mission} = MissionEnvironment.new(capabilities: [])

    limit_overrides =
      limit_overrides
      |> Keyword.put_new(:run_duration_ms, 60_000)
      |> Keyword.put_new(:workflow_timeout_ms, 30_000)

    {:ok, limits} = Limits.new(limit_overrides)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "parallel-timeout")

    RunConfig.new(
      workflow_environment: workflow,
      missions: %{"default" => mission},
      input: %{},
      limits: limits,
      event_sink: sink
    )
  end

  defp run_park_workflow(park_ms, limit_overrides) do
    {:ok, config} = park_config(park_ms, limit_overrides)
    Kernel.run(~S[(return (pcalls #(tool/park {})))], config)
  end

  test "a narrowed parallel_timeout_ms fails a parked pcalls at the configured deadline" do
    {:ok, config} = park_config(10_000, parallel_timeout_ms: 200)
    started = System.monotonic_time(:millisecond)

    assert {:error, error} = Kernel.run(~S[(return (pcalls #(tool/park {})))], config)

    elapsed = System.monotonic_time(:millisecond) - started
    assert error.kind == :limit_exceeded
    assert error.reason == :timeout

    assert error.details[:limit] == :parallel_timeout_ms,
           "the failure must name the limit that fired, got #{inspect(error.details)}"

    assert %{data: %{reason: :timeout, limit: :parallel_timeout_ms, limit_ms: 200}} =
             EventSink.events(config.event_sink)
             |> Enum.find(&(&1.type == "limit-exceeded"))

    assert elapsed < 5_000,
           "the narrowed deadline must fire well before the old 5s floor, took #{elapsed}ms"
  end

  # The worker spins rather than parking in a capability. A workflow capability
  # is dispatched with `workflow_timeout_ms` as its own timeout, so parking here
  # would race the 300 ms cap against a 300 ms capability deadline: whichever
  # timer the scheduler serviced first decided whether the run failed or the
  # `pcalls` returned a recoverable `provider_timeout` value. Only one timer can
  # stop pure work, and it is the one under test.
  test "a cap bound by a shorter workflow_timeout_ms is attributed to it" do
    {:ok, config} =
      park_config(10_000,
        workflow_timeout_ms: 300,
        run_duration_ms: 60_000,
        parallel_timeout_ms: 30_000
      )

    started = System.monotonic_time(:millisecond)

    assert {:error, error} =
             Kernel.run(
               "(return (pcalls #(#{long_running_body(4)})))",
               config
             )

    elapsed = System.monotonic_time(:millisecond) - started
    assert error.kind == :limit_exceeded

    assert error.details[:limit] == :workflow_timeout_ms,
           "the binding limit was workflow_timeout_ms, got #{inspect(error.details)}"

    assert elapsed < 5_000, "the 300ms cap must fire fast, took #{elapsed}ms"
  end

  test "the narrowed limit reaches REPL parallel operations" do
    {:ok, config} =
      park_config(10_000, parallel_timeout_ms: 200, evaluation_timeout_ms: 5_000)

    {:ok, session} = ReplSession.new(config: config)
    started = System.monotonic_time(:millisecond)

    assert {:error, step, _session} =
             ReplSession.eval(session, ~S[(pcalls #(tool/park {}))])

    elapsed = System.monotonic_time(:millisecond) - started
    assert step.fail.reason == :timeout

    assert elapsed < 4_000,
           "the REPL must honor parallel_timeout_ms, not the library 5s default, took #{elapsed}ms"
  end

  # Proves the removal of the unreachable hard-coded 5s ceiling: a parallel
  # operation over live-model-scale latency now completes under the default.
  # The cases above already pin that `parallel_timeout_ms` is honored; this
  # one parks for 5.5 s on purpose, so it belongs on `mix nightly`.
  @tag :nightly
  @tag timeout: 30_000
  test "a parallel operation outlives the old hard-coded 5s ceiling under the default limit" do
    assert {:ok, result} = run_park_workflow(5_500, [])
    assert [%{"status" => "ok", "value" => %{"parked_ms" => 5_500}}] = result.value
  end
end
