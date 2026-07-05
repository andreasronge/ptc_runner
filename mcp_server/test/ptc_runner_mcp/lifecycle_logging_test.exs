defmodule PtcRunnerMcp.LifecycleLoggingTest do
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Application
  alias PtcRunnerMcp.Http.Config, as: HttpConfig
  alias PtcRunnerMcp.Http.SessionRegistry, as: HttpSessionRegistry
  alias PtcRunnerMcp.Lifecycle
  alias PtcRunnerMcp.Log
  alias PtcRunnerMcp.McpTestHelpers
  alias PtcRunnerMcp.Sessions.Registry, as: SessionsRegistry
  alias PtcRunnerMcp.TurnLogCollector
  alias PtcRunnerMcp.TurnLogConfig

  setup do
    original_log_level = Log.level()
    original_turn_log_config = TurnLogConfig.get()

    Log.set_level(:info)
    Lifecycle.reset_boot_id!()

    on_exit(fn ->
      Log.set_level(original_log_level)
      TurnLogConfig.set(original_turn_log_config)
      TurnLogConfig.put_collector(nil)
      Lifecycle.reset_boot_id!()
    end)

    :ok
  end

  test "lifecycle fields include a stable boot id and OS pid" do
    first = Lifecycle.lifecycle_fields(%{event_detail: "one"})
    second = Lifecycle.lifecycle_fields(%{event_detail: "two"})

    assert is_binary(first.boot_id)
    assert first.boot_id == second.boot_id
    assert first.os_pid == System.pid()
    assert first.event_detail == "one"
  end

  @tag :tmp_dir
  test "prelude seed log includes boot fields and seed checksum", %{tmp_dir: dir} do
    path = Path.join(dir, "seed.clj")
    source = "(ns seeded)\n(defn value [] 42)\n"
    File.write!(path, source)

    lines =
      McpTestHelpers.capture_json_logs(fn ->
        assert %{prelude_store: _store} =
                 Application.maybe_seed_prelude_store(%{prelude_store_seed: path})
      end)

    [seeded] = Enum.filter(lines, &(&1["event"] == "prelude_store_seeded"))
    fields = seeded["fields"]

    assert fields["id"] == "seeded"
    assert fields["path"] == path
    assert fields["store_seed_checksum"] == sha256_hex(source)
    assert is_binary(fields["boot_id"])
    assert fields["os_pid"] == System.pid()
  end

  @tag :tmp_dir
  test "turn log collector logs start and terminate with the concrete turn-log path", %{
    tmp_dir: dir
  } do
    parent = self()
    name = :"turn_log_collector_#{System.unique_integer([:positive])}"

    logs =
      McpTestHelpers.capture_json_logs(fn ->
        {:ok, pid} = TurnLogCollector.start_link(dir: dir, name: name)
        Process.unlink(pid)
        path = TurnLogCollector.path(pid)
        send(parent, {:turn_log_path, path})
        GenServer.stop(pid, :shutdown)
      end)

    assert_receive {:turn_log_path, path}, 1_000

    start = Enum.find(logs, &(&1["event"] == "turn_log_collector_start"))
    terminate = Enum.find(logs, &(&1["event"] == "turn_log_collector_terminate"))

    assert start
    assert terminate

    start_fields = start["fields"]
    terminate_fields = terminate["fields"]

    assert start_fields["turn_log_dir"] == dir
    assert start_fields["turn_log_path"] == path
    assert terminate_fields["turn_log_path"] == path
    assert terminate_fields["reason"] == ":shutdown"
  end

  test "stdio session registry logs start and terminate lifecycle events" do
    name = :"registry_#{System.unique_integer([:positive])}"

    logs =
      McpTestHelpers.capture_json_logs(fn ->
        {:ok, pid} = SessionsRegistry.start_link(name: name)
        Process.unlink(pid)
        GenServer.stop(pid, :shutdown)
      end)

    assert Enum.any?(logs, &(&1["event"] == "session_registry_start"))
    assert Enum.any?(logs, &(&1["event"] == "session_registry_terminate"))
  end

  test "stdio session registry logs terminate during supervisor shutdown" do
    name = :"registry_#{System.unique_integer([:positive])}"

    logs =
      McpTestHelpers.capture_json_logs(fn ->
        {:ok, sup} =
          Supervisor.start_link(
            [{SessionsRegistry, [name: name, trap_exit: true]}],
            strategy: :one_for_one
          )

        Process.unlink(sup)
        :ok = Supervisor.stop(sup, :shutdown, 1_000)
      end)

    terminate = Enum.find(logs, &(&1["event"] == "session_registry_terminate"))

    assert get_in(terminate, ["fields", "registry"]) == inspect(name)
    assert get_in(terminate, ["fields", "transport"]) == "stdio"
    assert get_in(terminate, ["fields", "reason"]) == ":shutdown"
  end

  test "stdio session registry survives normal exit from a linked starter" do
    name = :"registry_#{System.unique_integer([:positive])}"
    parent = self()

    starter =
      spawn(fn ->
        {:ok, pid} = SessionsRegistry.start_link(name: name)
        send(parent, {:registry_started, pid})
      end)

    starter_ref = Process.monitor(starter)
    assert_receive {:registry_started, pid}, 1_000
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^starter_ref, :process, ^starter, :normal}, 1_000
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 100

    Process.unlink(pid)
    GenServer.stop(pid, :shutdown)
  end

  test "HTTP session registry logs start and terminate lifecycle events" do
    {:ok, cfg} =
      HttpConfig.resolve(%{
        http: true,
        http_auth_token: String.duplicate("c", 32),
        http_instance_label: "lifecycle-test"
      })

    logs =
      McpTestHelpers.capture_json_logs(fn ->
        name = :"http_registry_#{System.unique_integer([:positive])}"
        {:ok, pid} = HttpSessionRegistry.start_link(config: cfg, name: name)
        Process.unlink(pid)
        GenServer.stop(pid, :shutdown)
      end)

    start = Enum.find(logs, &(&1["event"] == "session_registry_start"))
    terminate = Enum.find(logs, &(&1["event"] == "session_registry_terminate"))

    assert get_in(start, ["fields", "transport"]) == "http"
    assert get_in(start, ["fields", "instance"]) == "lifecycle-test"
    assert get_in(terminate, ["fields", "transport"]) == "http"
    assert get_in(terminate, ["fields", "reason"]) == ":shutdown"
  end

  defp sha256_hex(source) do
    :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  end
end
