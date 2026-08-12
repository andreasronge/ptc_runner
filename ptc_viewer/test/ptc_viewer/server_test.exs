defmodule PtcViewer.ServerTest do
  use ExUnit.Case, async: false

  alias PtcViewer.{TestInspectionAdapter, TestReplAdapter}

  test "inspection startup preserves an unsupported schema version error" do
    assert {:error,
            {:unsupported_inspection_schema_version, %{artifact_version: 4, supported_version: 5}}} =
             PtcViewer.start(
               inspection_file: "run.inspection.jsonl",
               inspection_adapter: TestInspectionAdapter,
               open: false
             )
  end

  test "requested REPL connection and feature failures fail startup" do
    assert {:error, :connection_rejected} =
             PtcViewer.start(
               port: 0,
               repl_adapter: TestReplAdapter,
               repl_config: %{connect_error: true},
               open: false
             )

    assert {:error, :invalid_repl_features} =
             PtcViewer.start(
               port: 0,
               repl_adapter: TestReplAdapter,
               repl_config: %{bad_features: true, test_pid: self()},
               open: false
             )

    assert {:error, :invalid_repl_adapter} =
             PtcViewer.start(port: 0, repl_adapter: String, repl_config: %{}, open: false)
  end

  test "lifecycle owner exposes the bound listener and performs orderly REPL shutdown" do
    {:ok, viewer} =
      PtcViewer.start(
        port: 0,
        repl_adapter: TestReplAdapter,
        repl_config: %{test_pid: self()},
        open: false
      )

    state = :sys.get_state(viewer)
    backend = state.connection.backend
    store = state.repl_store
    backend_ref = Process.monitor(backend)
    store_ref = Process.monitor(store)

    assert {:ok, {{127, 0, 0, 1}, port}} = PtcViewer.listener_info(viewer)
    assert port > 0
    assert :ok = PtcViewer.stop(viewer)
    assert_receive {:DOWN, ^store_ref, :process, ^store, :normal}, 1_000
    assert_receive {:DOWN, ^backend_ref, :process, ^backend, _reason}, 1_000
  end

  test "unexpected store death fails the whole local server closed" do
    {:ok, viewer} =
      PtcViewer.start(
        port: 0,
        repl_adapter: TestReplAdapter,
        repl_config: %{test_pid: self()},
        open: false
      )

    %{repl_store: store, connection: connection} = :sys.get_state(viewer)
    viewer_ref = Process.monitor(viewer)
    backend_ref = Process.monitor(connection.backend)
    Process.unlink(store)
    Process.exit(store, :kill)

    assert_receive {:DOWN, ^viewer_ref, :process, ^viewer, :repl_store_failed}, 2_000
    assert_receive {:DOWN, ^backend_ref, :process, _pid, _reason}, 2_000
  end

  test "killing the lifecycle owner terminates the connected backend" do
    {:ok, viewer} =
      PtcViewer.start(
        port: 0,
        repl_adapter: TestReplAdapter,
        repl_config: %{test_pid: self()},
        open: false
      )

    %{connection: connection} = :sys.get_state(viewer)
    backend_ref = Process.monitor(connection.backend)
    Process.exit(viewer, :kill)

    assert_receive {:DOWN, ^backend_ref, :process, _pid, _reason}, 2_000
  end

  test "orderly stop reports a close acknowledgement failure" do
    {:ok, viewer} =
      PtcViewer.start(
        port: 0,
        repl_adapter: TestReplAdapter,
        repl_config: %{test_pid: self()},
        open: false
      )

    %{connection: connection, repl_store: store} = :sys.get_state(viewer)
    assert {:ok, _bootstrap} = PtcViewer.ReplStore.bootstrap(store)
    TestReplAdapter.set_ack_failures(connection.backend, 10)

    assert {:error, :adapter_failure} = PtcViewer.stop(viewer)
  end

  test "OTP status redacts the connected backend capability" do
    {:ok, viewer} =
      PtcViewer.start(
        port: 0,
        repl_adapter: TestReplAdapter,
        repl_config: %{test_pid: self()},
        open: false
      )

    backend = :sys.get_state(viewer).connection.backend
    status = viewer |> :sys.get_status() |> inspect()
    refute status =~ inspect(backend)
    refute status =~ "connection"
    assert :ok = PtcViewer.stop(viewer)
  end

  test "unexpected listener death fails the whole lifecycle closed" do
    {:ok, viewer} =
      PtcViewer.start(
        port: 0,
        repl_adapter: TestReplAdapter,
        repl_config: %{test_pid: self()},
        open: false
      )

    %{bandit: bandit, connection: connection} = :sys.get_state(viewer)
    viewer_ref = Process.monitor(viewer)
    backend_ref = Process.monitor(connection.backend)
    Supervisor.stop(bandit, :shutdown)

    assert_receive {:DOWN, ^viewer_ref, :process, ^viewer, :viewer_listener_failed}, 2_000
    assert_receive {:DOWN, ^backend_ref, :process, _pid, _reason}, 2_000
  end
end
