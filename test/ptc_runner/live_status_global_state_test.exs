defmodule PtcRunner.LiveStatusGlobalStateTest do
  # async: false — three cases set PTC_VIEWER_URL or PTC_VIEWER_TOKEN, which every Kernel.run in
  # the VM reads (class D), and one asserts that completion returns within 500 ms, which a loaded
  # async phase cannot promise (class A). The rest of live-status coverage is async.
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.LiveStatusFixtures

  @moduletag :capture_log

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.LiveStatus.Reporter
  alias PtcRunner.LiveStatus.Target
  alias PtcRunner.MixCommandAdapter
  alias PtcRunner.TestSupport.HTTPRequest

  @tag :tmp_dir
  test "an externally attached CLI run carries the manifest application identity", %{tmp_dir: dir} do
    manifest = Path.join(dir, "ptc.json")
    File.write!(Path.join(dir, "app.clj"), "(ns app) (defn run [input] input)")

    File.write!(manifest, ~S|{
      "version": 1,
      "labels": {"name": "invoice-triage"},
      "workflow": {
        "components": [{"id": "app", "path": "app.clj"}],
        "entry": "app/run"
      },
      "input": {"value": {}}
    }|)

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    parent = self()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, request} = HTTPRequest.receive_complete(socket)
        send(parent, {:external_cli_request, request})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        :ok = :gen_tcp.close(socket)
      end)

    server_ref = Process.monitor(server)

    System.put_env("PTC_VIEWER_URL", "http://127.0.0.1:#{port}")
    on_exit(fn -> System.delete_env("PTC_VIEWER_URL") end)

    assert %{exit_status: 0} = MixCommandAdapter.execute(["run", manifest])
    assert_receive {:external_cli_request, request}, 2_000
    assert request =~ ~s|"label":"invoice-triage · app/run"|
    :ok = :gen_tcp.close(listener)
    assert_receive {:DOWN, ^server_ref, :process, ^server, :normal}, 2_000
  end

  test "a blocked target cannot delay run completion and its worker is terminated" do
    test_process = self()

    {:ok, target} =
      Target.new(fn _run_id, frame ->
        send(test_process, {:blocked_delivery, self(), frame.phase})

        receive do
          :never -> :ok
        end
      end)

    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "blocked-live-target")
    {:ok, config} = run_config(limits, sink, %{})
    {:ok, run_state} = RunState.start(limits)
    {:ok, reporter} = Reporter.start(target, config, run_state)

    assert_receive {:blocked_delivery, delivery, "running"}, 1_000
    delivery_ref = Process.monitor(delivery)

    started = System.monotonic_time(:millisecond)
    assert :ok = Reporter.complete(reporter, :ok, nil, nil)
    assert System.monotonic_time(:millisecond) - started < 500
    assert :ok = Reporter.stop(reporter)

    assert_receive {:DOWN, ^delivery_ref, :process, ^delivery, :killed}, 2_000
    reporter_ref = Process.monitor(reporter)
    assert_receive {:DOWN, ^reporter_ref, :process, ^reporter, :normal}, 2_000
    assert :ok = RunState.stop(run_state)
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
end
