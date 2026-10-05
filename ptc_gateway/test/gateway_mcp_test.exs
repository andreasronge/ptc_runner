defmodule PtcGatewayMCPTest do
  use ExUnit.Case, async: false
  import PtcGateway.TestSupport.GatewayFixture
  alias PtcRunner.Kernel.{HostConfig, HostInstallation, InstallationCatalog, ServingTemplate}
  alias PtcRunner.TestSupport.{MCPTLSProxy, WarmMCPFixture}

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  @tag :tmp_dir
  test "static-header HTTP acquisitions are shared per tool under concurrent gateway calls", %{
    tmp_dir: dir
  } do
    upstream = WarmMCPFixture.http()
    on_exit(upstream.close)
    tls = MCPTLSProxy.start(dir, upstream.endpoint)
    on_exit(tls.close)

    transport = %{
      "type" => "streamable_http",
      "endpoint" => tls.endpoint,
      "auth" => [%{"scheme" => "api_key", "binding" => "upstream", "header" => "X-Key"}]
    }

    {path, config} = mcp_fixture(dir, transport)
    assert {:ok, owner} = PtcGateway.start_link(path)
    on_exit(fn -> stop(owner) end)

    tasks =
      for query <- ["one", "two", "three", "four"], do: Task.async(fn -> call(config, query) end)

    for {task, query} <- Enum.zip(tasks, ["one", "two", "three", "four"]) do
      result = Task.await(task)
      assert result.status == 200
      assert result.body["result"]["structuredContent"] == %{"text" => [query]}
    end

    for _ <- 1..3, do: assert_received({:upstream, "server/discover", _})
    refute_received {:upstream, "server/discover", _}
    assert_received {:upstream, "tools/call", %{"x-key" => "fixture-key"}}
    assert response(config, "/health/ready").status == 200
  end

  @tag :tmp_dir
  test "stdio tools stay warm across calls", %{tmp_dir: dir} do
    marker = Path.join(dir, "stdio.log")
    script = Path.expand("../../test/support/mcp_stdio_source_fixture.sh", __DIR__)
    transport = %{"type" => "stdio", "command" => "/bin/sh", "args" => [script, marker]}
    {path, config} = mcp_fixture(dir, transport, upstream_tool: "structured")
    assert {:ok, owner} = PtcGateway.start_link(path)
    on_exit(fn -> stop(owner) end)

    for _ <- 1..3,
        do: assert(call(config, "x").body["result"]["structuredContent"] == %{"value" => 42})

    assert length(Regex.scan(~r/server\/discover/, File.read!(marker))) == 3
    warm = :sys.get_state(owner).warm
    runtime = :sys.get_state(warm).runtimes["a"]
    [transport] = :sys.get_state(runtime).opened.providers.mcp_transports
    Process.exit(transport.pid, :kill)

    PtcRunner.TestSupport.Eventually.assert_eventually(fn ->
      response(config, "/health/ready").status == 503
    end)

    assert call(config, "x").status == 503
  end

  @tag :tmp_dir
  @tag :nightly
  test "execution-owner death cannot finish drain before detached transport work settles", %{
    tmp_dir: dir
  } do
    parent = self()

    upstream =
      WarmMCPFixture.http(
        on_call: fn _ ->
          send(parent, {:upstream_blocked, self()})
          receive do: (:release -> :ok)
        end
      )

    on_exit(upstream.close)
    {path, config} = mcp_fixture(dir, WarmMCPFixture.http_transport(upstream.endpoint))
    {:ok, gateway} = PtcGateway.start_link(path)
    on_exit(fn -> stop(gateway) end)
    caller = Task.async(fn -> call(config, "held") end)
    assert_receive {:upstream_blocked, upstream_worker}, 5_000
    warm = :sys.get_state(gateway).warm
    runtime = :sys.get_state(warm).runtimes["a"]
    state = :sys.get_state(runtime)
    [{key, %{owner: {execution_owner, _}}}] = Map.to_list(state.borrows)
    [transport] = state.opened.providers.mcp_transports
    :sys.suspend(transport.pid)
    Process.exit(execution_owner, :kill)

    PtcRunner.TestSupport.Eventually.assert_eventually(fn ->
      match?(%{settling: {_pid, _}}, :sys.get_state(runtime).borrows[key])
    end)

    assert map_size(:sys.get_state(runtime).borrows) == 1

    draining =
      Task.async(fn ->
        PtcRunner.Kernel.ProviderRuntime.drain(
          runtime,
          System.monotonic_time(:millisecond) + 10_000
        )
      end)

    assert Task.yield(draining, 0) == nil
    :sys.resume(transport.pid)
    assert :ok = Task.await(draining, 15_000)
    assert map_size(:sys.get_state(runtime).borrows) == 0
    send(upstream_worker, :release)
    _response = Task.await(caller, 15_000)
  end

  @tag :tmp_dir
  test "selected OAuth and workflow catalogs are refused before capture across mixed tools", %{
    tmp_dir: dir
  } do
    upstream = WarmMCPFixture.http()
    on_exit(upstream.close)
    {path, config} = mcp_fixture(dir, WarmMCPFixture.http_transport(upstream.endpoint))
    flush_upstream()
    later = Path.join(dir, "later")
    File.mkdir!(later)

    for file <- ["main.clj", "schema.json", "app.json"],
        do: File.cp!(Path.join(dir, file), Path.join(later, file))

    manifest = later |> Path.join("app.json") |> File.read!() |> Jason.decode!()

    manifest =
      put_in(manifest, ["providers", "mission", Access.at(0), "name"], "oauth")
      |> put_in(["missions", "default", "providers"], ["oauth"])

    File.write!(Path.join(later, "app.json"), Jason.encode!(manifest))
    host_path = Path.join(dir, "host.json")
    host = host_path |> File.read!() |> Jason.decode!()
    oauth = Map.put(host["install"]["remote"], "transport", oauth_transport())
    host = put_in(host, ["install", "oauth"], oauth)
    File.write!(host_path, Jason.encode!(host))
    File.rm!(Path.join(dir, "upstream.key"))
    assert {:ok, ignored} = PtcGateway.start_link(path)
    stop(ignored)
    flush_upstream()
    {:ok, loaded} = HostConfig.load(host_path)
    {:ok, catalog} = HostInstallation.catalog(loaded)
    on_exit(fn -> InstallationCatalog.close(catalog) end)

    assert {:error, :provider_runtime_unsupported} =
             ServingTemplate.from_directory(Path.join(later, "app.json"), loaded.limits,
               providers: catalog
             )

    config =
      update_in(config, ["tools"], fn tools ->
        Enum.map(tools, fn tool ->
          if tool["name"] == "z",
            do: put_in(tool, ["application", "manifest"], "later/app.json"),
            else: tool
        end)
      end)

    {:ok, package, _input} =
      PtcRunner.Kernel.ApplicationPackage.acquire_directory(Path.join(later, "app.json"),
        installed_limits: loaded.limits,
        omit_input: true
      )

    config =
      update_in(config, ["tools"], fn tools ->
        Enum.map(tools, fn tool ->
          if tool["name"] == "z",
            do:
              Map.put(
                tool,
                "expected_application_content_digest",
                "sha256:" <> package.application_content_digest
              ),
            else: tool
        end)
      end)

    File.write!(path, Jason.encode!(config))
    assert {:error, :provider_source_unsupported} = PtcGateway.start_link(path)
    refute_received {:upstream, _, _}
    manifest = Path.join(dir, "app.json") |> File.read!() |> Jason.decode!()

    manifest =
      manifest
      |> Map.put("providers", %{
        "workflow" => [%{"name" => "remote", "config" => %{"catalog" => true}}]
      })
      |> Map.delete("missions")

    File.write!(Path.join(dir, "app.json"), Jason.encode!(manifest))

    assert {:error, :provider_runtime_unsupported} =
             ServingTemplate.from_directory(Path.join(dir, "app.json"), loaded.limits,
               providers: catalog
             )

    {:ok, package, _input} =
      PtcRunner.Kernel.ApplicationPackage.acquire_directory(Path.join(dir, "app.json"),
        installed_limits: loaded.limits,
        omit_input: true
      )

    config =
      update_in(config, ["tools"], fn tools ->
        Enum.map(tools, fn tool ->
          tool
          |> put_in(["application", "manifest"], "app.json")
          |> Map.put(
            "expected_application_content_digest",
            "sha256:" <> package.application_content_digest
          )
        end)
      end)

    File.write!(path, Jason.encode!(config))
    assert {:error, :provider_source_unsupported} = PtcGateway.start_link(path)

    assert PtcGateway.StartupError.normalize(:provider_runtime_unsupported) ==
             :provider_source_unsupported

    refute_received {:upstream, _, _}
  end

  defp call(config, query) do
    result =
      mcp(config, "tools/call", query,
        params: %{
          "name" => "a",
          "arguments" => %{"program" => ~s|(return (tool/remote.echo {"query" "#{query}"}))|}
        },
        headers: [{"mcp-name", "a"}]
      )

    if is_binary(result.body) do
      [_, event, ""] = String.split(result.body, "\n\n")
      ["event: message", "data: " <> payload] = String.split(event, "\n")
      %{result | body: Jason.decode!(payload)}
    else
      result
    end
  end

  defp oauth_transport do
    %{
      "type" => "streamable_http",
      "endpoint" => "https://mcp.example.test/mcp",
      "oauth" => %{
        "installation_id" => "oauth-fixture",
        "issuer" => "https://auth.example.test",
        "scope_ceiling" => [],
        "client" => %{
          "registration" => "pre_registered",
          "client_id" => "fixture",
          "token_endpoint_auth_method" => "client_secret_basic",
          "client_secret_binding" => "upstream",
          "grant_types" => ["authorization_code"],
          "redirect_uris" => ["https://client.example.test/callback"]
        }
      }
    }
  end

  defp flush_upstream do
    receive do
      {:upstream, _, _} -> flush_upstream()
    after
      0 -> :ok
    end
  end
end
