defmodule PtcRunner.LiveStatusTest do
  # async: false — mutates the PTC_VIEWER_URL environment variable.
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.LiveStatus.Reporter
  alias PtcRunner.LiveStatus.Target

  @moduletag :capture_log

  test "telemetry delivery is isolated to its correlated run" do
    run_ref = self()
    other_run_ref = spawn(fn -> :ok end)
    handler_config = {self(), run_ref}

    assert :ok =
             Reporter.handle_telemetry(
               [:ptc_runner, :capability, :start],
               %{},
               %{live_run: other_run_ref},
               handler_config
             )

    refute_receive {:live_telemetry, _, _, _}

    assert :ok =
             Reporter.handle_telemetry(
               [:ptc_runner, :capability, :start],
               %{},
               %{live_run: run_ref},
               handler_config
             )

    assert_receive {:live_telemetry, [:ptc_runner, :capability, :start], %{}, %{}}
  end

  test "a run succeeds unchanged when the configured viewer is unreachable" do
    # Grab a port that is guaranteed closed by binding and releasing it.
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    System.put_env("PTC_VIEWER_URL", "http://127.0.0.1:#{port}")
    on_exit(fn -> System.delete_env("PTC_VIEWER_URL") end)

    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "live-status-dead-viewer")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: 42}} = Kernel.run("(return 42)", config)
  end

  test "the terminal frame names the timeout limit that actually fired" do
    parent = self()
    {:ok, target} = Target.new(fn _run_id, frame -> send(parent, {:live_frame, frame}) end)

    {:ok, park} =
      Capability.new(
        name: "park",
        description: "Park until the parallel operation times out.",
        input_schema: %{"type" => "object"},
        callback: fn _arguments ->
          receive do
            :never -> {:ok, %{}}
          after
            10_000 -> {:ok, %{}}
          end
        end
      )

    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [park])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, limits} =
      Limits.new(
        run_duration_ms: 10_000,
        workflow_timeout_ms: 5_000,
        parallel_timeout_ms: 200
      )

    {:ok, sink} = EventSink.start(:normal, limits, run_id: "live-parallel-timeout")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:error, %{kind: :limit_exceeded}} =
             PtcRunner.LiveStatus.with_target(target, fn ->
               Kernel.run(~S[(return (pcalls #(tool/park {})))], config)
             end)

    assert_receive {:live_frame,
                    %{
                      phase: "error",
                      outcome_reason:
                        "parallel_timeout_ms limit 200 ms was exceeded during execution"
                    }},
                   2_000
  end
end
