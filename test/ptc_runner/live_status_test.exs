defmodule PtcRunner.LiveStatusTest do
  # async: false — mutates the PTC_VIEWER_URL environment variable.
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
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

  test "the reporter stops when the run owner dies" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, limits} = Limits.new()
        {:ok, sink} = EventSink.start(:normal, limits, run_id: "owner-bound-live-status")
        {:ok, config} = run_config(limits, sink, %{})
        {:ok, run_state} = RunState.start(limits)
        {:ok, target} = Target.new(fn _run_id, _frame -> :ok end)
        {:ok, reporter} = Reporter.start(target, config, run_state)
        send(parent, {:reporter, reporter})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:reporter, reporter}
    reporter_ref = Process.monitor(reporter)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^reporter_ref, :process, ^reporter, _reason}, 2_000
  end

  test "OTP status redacts private input and the HTTP bearer token" do
    token = "PRIVATE_VIEWER_BEARER_TOKEN_1234567890"
    previous = System.get_env("PTC_VIEWER_TOKEN")
    System.put_env("PTC_VIEWER_TOKEN", token)

    on_exit(fn ->
      if previous,
        do: System.put_env("PTC_VIEWER_TOKEN", previous),
        else: System.delete_env("PTC_VIEWER_TOKEN")
    end)

    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "private-status")
    {:ok, config} = run_config(limits, sink, %{"secret" => "PRIVATE_LIVE_INPUT_MARKER"})
    {:ok, run_state} = RunState.start(limits)
    {:ok, reporter} = Reporter.start("http://127.0.0.1:1", config, run_state)

    status = inspect(:sys.get_status(reporter), limit: :infinity, printable_limit: :infinity)
    refute status =~ "PRIVATE_LIVE_INPUT_MARKER"
    refute status =~ token

    assert :ok = Reporter.stop(reporter)
    assert :ok = RunState.stop(run_state)
  end

  test "the HTTP reporter percent-encodes the complete run id as one path segment" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    parent = self()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
        send(parent, {:http_request, request})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        :ok = :gen_tcp.close(socket)
      end)

    server_ref = Process.monitor(server)

    run_id = "run /?# café"
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)
    {:ok, config} = run_config(limits, sink, %{})
    {:ok, run_state} = RunState.start(limits)
    {:ok, reporter} = Reporter.start("http://127.0.0.1:#{port}", config, run_state)

    assert_receive {:http_request, request}, 2_000
    assert request =~ "POST /api/live/runs/run%20%2F%3F%23%20caf%C3%A9 HTTP/1.1"

    assert :ok = Reporter.stop(reporter)
    assert :ok = RunState.stop(run_state)
    :ok = :gen_tcp.close(listener)
    assert_receive {:DOWN, ^server_ref, :process, ^server, :normal}
  end

  test "live timeout formatting names the run-duration limit" do
    assert {:ok, "run_duration_ms limit 200 ms was exceeded during execution"} =
             RuntimeLimitDiagnostic.live_timeout_message(
               :run_duration_ms,
               200,
               :execution
             )
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
    park = park_capability()
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

  test "a real run deadline reports the configured run-duration ceiling" do
    parent = self()
    {:ok, target} = Target.new(fn _run_id, frame -> send(parent, {:live_frame, frame}) end)
    {:ok, workflow} = WorkflowEnvironment.new(capabilities: [park_capability()])
    {:ok, mission} = MissionEnvironment.new([])

    {:ok, limits} =
      Limits.new(
        run_duration_ms: 200,
        workflow_timeout_ms: 5_000,
        parallel_timeout_ms: 5_000
      )

    {:ok, sink} = EventSink.start(:normal, limits, run_id: "live-run-duration-timeout")
    {:ok, config} = run_config(limits, sink, %{}, workflow, mission)

    assert {:error, %{kind: :limit_exceeded, details: details}} =
             PtcRunner.LiveStatus.with_target(target, fn ->
               Kernel.run(~S[(return (pcalls #(tool/park {})))], config)
             end)

    assert details.limit == :run_duration_ms
    assert details.limit_ms == 200

    assert_receive {:live_frame,
                    %{
                      phase: "error",
                      outcome_reason: "run_duration_ms limit 200 ms was exceeded during execution"
                    }},
                   2_000
  end

  defp run_config(limits, sink, input) do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    run_config(limits, sink, input, workflow, mission)
  end

  defp run_config(limits, sink, input, workflow, mission) do
    RunConfig.new(
      workflow_environment: workflow,
      missions: %{"default" => mission},
      input: input,
      limits: limits,
      event_sink: sink
    )
  end

  defp park_capability do
    {:ok, capability} =
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

    capability
  end
end
