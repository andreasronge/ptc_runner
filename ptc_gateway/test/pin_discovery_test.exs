defmodule PtcGateway.PinDiscoveryTest do
  use ExUnit.Case, async: false
  import PtcGateway.TestSupport.GatewayFixture
  alias PtcGateway.PinDiscovery
  alias PtcRunner.Kernel.GatewayConfig
  alias PtcRunner.TestSupport.WarmMCPFixture

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  @tag :tmp_dir
  test "missing and stale pins are discovery-only; no bearer or filesystem initialization", %{
    tmp_dir: dir
  } do
    {path, config} = fixture(dir)
    config = Map.put(config, "artifacts", %{"root" => "missing/artifacts", "inspection" => true})
    config = update_in(config["tools"], &Enum.map(&1, fn tool -> Map.drop(tool, pin_keys()) end))
    File.write!(path, Jason.encode!(config))
    File.rm!(Path.join(dir, "host.json"))
    File.write!(Path.join(dir, "host.json"), Jason.encode!(%{"install" => %{}}))

    assert {:error, :config_invalid} = GatewayConfig.load(path)
    assert {:ok, pins} = PinDiscovery.discover(path)
    assert Map.keys(pins) |> Enum.sort() == ["a", "z"]
    assert pins["a"]["installation_config_pins"] == %{}
    assert pins["a"]["provider_snapshot_pins"] == %{}
    refute File.exists?(Path.join(dir, "missing"))

    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, config["listen"]["port"], [], 1000)

    config =
      update_in(
        config["tools"],
        &Enum.map(&1, fn tool ->
          Map.merge(tool, %{
            "expected_application_content_digest" => "sha256:" <> String.duplicate("0", 64),
            "installation_config_pins" => %{},
            "provider_snapshot_pins" => %{}
          })
        end)
      )

    File.write!(path, Jason.encode!(config))
    assert {:ok, ^pins} = PinDiscovery.discover(path)

    File.write!(
      Path.join(dir, "host.json"),
      Jason.encode!(%{
        "credentials" => %{"gateway" => %{"env" => "GATEWAY_TEST_TOKEN"}},
        "install" => %{}
      })
    )

    File.write!(path, Jason.encode!(Map.delete(config, "artifacts")))
    assert {:error, :application_content_digest_mismatch} = PtcGateway.start_link(path)
  end

  @tag :tmp_dir
  test "MCP discovery matches serving pins and closes before output without reading bearer", %{
    tmp_dir: dir
  } do
    server = WarmMCPFixture.http()
    on_exit(server.close)
    {path, config} = mcp_fixture(dir, WarmMCPFixture.http_transport(server.endpoint))
    File.rm!(Path.join(dir, "gateway.key"))
    config = Map.put(config, "artifacts", %{"root" => "uncreated", "trace" => true})
    File.write!(path, Jason.encode!(config))
    assert {:ok, discovered} = PinDiscovery.discover(path)

    for tool <- config["tools"] do
      assert discovered[tool["name"]] |> Jason.encode!() |> Jason.decode!() ==
               Map.take(tool, pin_keys())
    end

    refute File.exists?(Path.join(dir, "audit"))
    refute File.exists?(Path.join(dir, "uncreated"))
  end

  @tag :tmp_dir
  test "selected credentials are required and the exact env scope restores on success and failure",
       %{tmp_dir: dir} do
    server = WarmMCPFixture.http()
    on_exit(server.close)
    tls = PtcRunner.TestSupport.MCPTLSProxy.start(dir, server.endpoint)
    on_exit(tls.close)
    {path, _config} = mcp_fixture(dir, %{"type" => "streamable_http", "endpoint" => tls.endpoint})
    host_path = Path.join(dir, "host.json")
    host = Jason.decode!(File.read!(host_path))
    host = put_in(host, ["credentials", "upstream"], %{"env" => "PTC_DISCOVERY_KEY"})

    host =
      put_in(host, ["install", "remote", "transport", "auth"], [
        %{"scheme" => "api_key", "binding" => "upstream", "header" => "X-Key"}
      ])

    File.write!(host_path, Jason.encode!(host))
    previous = System.get_env("PTC_DISCOVERY_KEY")
    System.delete_env("PTC_DISCOVERY_KEY")

    on_exit(fn ->
      if previous,
        do: System.put_env("PTC_DISCOVERY_KEY", previous),
        else: System.delete_env("PTC_DISCOVERY_KEY")
    end)

    env = Path.join(dir, "capture.env")
    File.write!(env, "PTC_DISCOVERY_KEY=selected-key\nPTC_DISCOVERY_EXTRA=temporary\n")
    extra = System.get_env("PTC_DISCOVERY_EXTRA")
    requester = Task.async(fn -> PinDiscovery.discover(path) end)
    assert {:error, :credential_unavailable} = Task.await(requester, :infinity)
    assert {:ok, _} = PinDiscovery.discover(path, env_file: env)
    assert System.get_env("PTC_DISCOVERY_KEY") == nil
    assert System.get_env("PTC_DISCOVERY_EXTRA") == extra
    File.write!(env, "PTC_DISCOVERY_KEY=\nPTC_DISCOVERY_EXTRA=temporary\n")
    assert {:error, :credential_unavailable} = PinDiscovery.discover(path, env_file: env)
    assert System.get_env("PTC_DISCOVERY_KEY") == nil
    assert System.get_env("PTC_DISCOVERY_EXTRA") == extra
    File.write!(env, "PTC_DISCOVERY_EXTRA=temporary\n")
    assert {:error, :credential_unavailable} = PinDiscovery.discover(path, env_file: env)
    assert System.get_env("PTC_DISCOVERY_EXTRA") == extra
  end

  @tag :tmp_dir
  test "a later acquisition failure closes earlier stdio resources and returns no output", %{
    tmp_dir: dir
  } do
    marker = Path.join(dir, "stdio.log")
    script = Path.expand("../../test/support/mcp_stdio_source_fixture.sh", __DIR__)

    transport = %{
      "type" => "stdio",
      "command" => "/bin/sh",
      "args" => [script, marker, "mark-close"]
    }

    {path, config} = mcp_fixture(dir, transport, upstream_tool: "structured")
    File.write!(marker, "")
    later = Path.join(dir, "later")
    File.mkdir!(later)

    for file <- ["main.clj", "schema.json", "app.json"],
        do: File.cp!(Path.join(dir, file), Path.join(later, file))

    manifest = Jason.decode!(File.read!(Path.join(later, "app.json")))
    manifest = put_in(manifest, ["providers", "mission", Access.at(0), "name"], "broken")
    manifest = put_in(manifest, ["missions", "default", "providers"], ["broken"])
    File.write!(Path.join(later, "app.json"), Jason.encode!(manifest))
    host_path = Path.join(dir, "host.json")
    host = Jason.decode!(File.read!(host_path))

    broken =
      put_in(host["install"]["remote"], ["transport", "args"], [
        script,
        Path.join(dir, "broken.log"),
        "unsupported-version"
      ])

    File.write!(host_path, Jason.encode!(put_in(host, ["install", "broken"], broken)))

    config =
      update_in(
        config["tools"],
        &Enum.map(&1, fn tool ->
          if tool["name"] == "z",
            do: put_in(tool, ["application", "manifest"], "later/app.json"),
            else: tool
        end)
      )

    File.write!(path, Jason.encode!(config))

    output =
      ExUnit.CaptureIO.capture_io(fn -> assert {:error, _} = PinDiscovery.discover(path) end)

    assert output == ""
    log = File.read!(marker)
    assert log =~ "server/discover"
    assert log =~ "session-closed"
    refute log =~ "tools/call"
    assert File.read!(Path.join(dir, "broken.log")) =~ "session-closed"
  end

  defp pin_keys,
    do: ~w(expected_application_content_digest installation_config_pins provider_snapshot_pins)
end
