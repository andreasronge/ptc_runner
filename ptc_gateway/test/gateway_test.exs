defmodule PtcGatewayTest do
  use ExUnit.Case, async: false
  alias PtcRunner.Kernel.{GatewayConfig, Limits, ServingTemplate, WarmProviderRuntime}

  @token String.duplicate("a", 32)
  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  @tag :tmp_dir
  test "multi-tool startup anchors paths, captures once, restores env and serves health", %{
    tmp_dir: dir
  } do
    {path, config} = fixture(Path.join(dir, "deployment"))
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    previous = System.get_env("GATEWAY_TEST_TOKEN")

    File.cd!(dir, fn ->
      assert {:ok, owner} = PtcGateway.start_link(path, env_file: "credentials.env")
      on_exit(fn -> stop(owner) end)
      metadata = PtcGateway.Domain.metadata(owner)
      assert Enum.map(metadata.tools, & &1["name"]) == ["a", "z"]
      assert System.get_env("GATEWAY_TEST_TOKEN") == previous
      assert WarmProviderRuntime.authenticate(PtcGateway.Domain.token_handle(owner), @token)
      refute inspect(:sys.get_status(owner)) =~ @token
      assert response(config, "/health/live").body == %{"status" => "live"}
      ready = response(config, "/health/ready")
      assert ready.status == 200
      assert ready.body == %{"status" => "ready"}
      assert ready.headers["cache-control"] == ["no-store"]
      refute Map.has_key?(ready.headers, "access-control-allow-origin")
      assert response(config, "/unknown").status == 404
      assert response(config, "/health/ready", method: :post).status == 405
      assert response(config, "/health/live", headers: [{"host", "evil.example"}]).status == 400

      assert :ok =
               WarmProviderRuntime.drain(
                 PtcGateway.Domain.token_handle(owner),
                 System.monotonic_time(:millisecond)
               )

      assert response(config, "/health/ready").status == 503
      assert response(config, "/health/live").status == 200
      GenServer.stop(owner)
    end)
  end

  @tag :tmp_dir
  test "invalid configuration never binds and errors stay closed", %{tmp_dir: dir} do
    {path, config} = fixture(dir)

    variants = [
      {put_in(config, ["listen", "address"], "0.0.0.0"), :config_invalid},
      {put_in(config, ["listen", "port"], 0), :config_invalid},
      {Map.put(config, "unknown", true), :config_invalid},
      {put_in(config, ["listen", "allowed_origins"], ["https://example.com/"]), :origin_invalid},
      {Map.put(config, "tools", [hd(config["tools"]), hd(config["tools"])]),
       :tool_name_duplicate},
      {Map.put(config, "private_audit", %{
         "directory" => "audit",
         "max_file_bytes" => 1024,
         "max_retained_files" => 2
       }), :audit_invalid}
    ]

    for {value, error} <- variants do
      File.write!(path, Jason.encode!(value))
      assert {:error, ^error} = PtcGateway.start_link(path)
    end

    File.write!(path, "{\"version\":1,\"version\":1}")
    assert {:error, :duplicate_json_key} = PtcGateway.start_link(path)
  end

  @tag :tmp_dir
  test "pins, write permission and missing credentials refuse startup", %{tmp_dir: dir} do
    {path, config} = fixture(dir)
    assert {:error, :credential_unavailable} = PtcGateway.start_link(path)
    assert {:ok, _} = GatewayConfig.load(path)

    stale =
      update_in(config, ["tools"], fn tools ->
        Enum.map(
          tools,
          &Map.put(
            &1,
            "expected_application_content_digest",
            "sha256:" <> String.duplicate("0", 64)
          )
        )
      end)

    File.write!(path, Jason.encode!(stale))
    assert {:error, :application_content_digest_mismatch} = PtcGateway.start_link(path)

    extra =
      update_in(config, ["tools"], fn tools ->
        Enum.map(
          tools,
          &Map.put(&1, "installation_config_pins", %{
            "extra" => &1["expected_application_content_digest"]
          })
        )
      end)

    File.write!(path, Jason.encode!(extra))
    assert {:error, :provider_pin_mismatch} = PtcGateway.start_link(path)
  end

  @tag :tmp_dir
  test "private audit opens owner-only, bounds rotation, and rejects links", %{tmp_dir: dir} do
    config = %{
      "directory" => Path.join(dir, "audit"),
      "max_file_bytes" => 1024,
      "max_retained_files" => 2
    }

    for _ <- 1..4 do
      assert {:ok, owner} = PtcGateway.PrivateAudit.start_link(config)
      assert inspect(:sys.get_status(owner)) =~ "redacted"
      GenServer.stop(owner)
    end

    names = File.ls!(config["directory"])
    assert length(names) == 2

    for name <- names do
      stat = File.stat!(Path.join(config["directory"], name))
      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end

    File.ln_s!(config["directory"], Path.join(dir, "link"))

    assert {:error, :audit_unavailable} =
             PtcGateway.PrivateAudit.start_link(%{config | "directory" => Path.join(dir, "link")})
  end

  @tag :tmp_dir
  test "write permission, audit readiness loss, and deterministic metadata", %{tmp_dir: dir} do
    {path, config} = fixture(dir, :write)
    assert {:error, :write_forbidden} = PtcGateway.start_link(path)

    config =
      update_in(
        config,
        ["tools"],
        &Enum.map(&1, fn tool -> Map.put(tool, "allow_write", true) end)
      )

    File.write!(path, Jason.encode!(config))
    assert {:error, :audit_invalid} = PtcGateway.start_link(path)

    config =
      Map.put(config, "private_audit", %{
        "directory" => "audit",
        "max_file_bytes" => 1024,
        "max_retained_files" => 2
      })

    File.write!(path, Jason.encode!(config))
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:ok, first} = PtcGateway.start_link(path, env_file: env)
    metadata = PtcGateway.Domain.metadata(first)
    GenServer.stop(first)
    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(owner) end)
    assert PtcGateway.Domain.metadata(owner) == metadata
    assert response(config, "/health/ready").status == 200
    audit = List.last(:sys.get_state(owner).children)
    ref = Process.monitor(audit)
    Process.exit(audit, :kill)
    assert_receive {:DOWN, ^ref, :process, ^audit, :killed}
    # Serialize behind the domain's linked-exit handling before querying health.
    _ = PtcGateway.Domain.metadata(owner)
    assert response(config, "/health/ready").status == 503
    assert response(config, "/health/live").status == 200
  end

  @tag :tmp_dir
  test "schema bounds and nested unknown keys reject before startup", %{tmp_dir: dir} do
    {path, config} = fixture(dir)

    variants =
      Enum.map(Map.keys(config), &Map.delete(config, &1)) ++
        [
          put_in(config, ["listen", "port"], 65536),
          put_in(config, ["listen", "path"], "/other"),
          put_in(config, ["listen", "extra"], true),
          put_in(config, ["admission", "max_concurrent_runs"], 0),
          put_in(config, ["admission", "max_active_provider_calls"], 65536),
          put_in(config, ["admission", "max_waiting_provider_calls"], -1),
          Map.put(config, "tools", []),
          Map.put(config, "tools", List.duplicate(hd(config["tools"]), 257)),
          update_in(
            config,
            ["tools"],
            &Enum.map(&1, fn tool -> Map.put(tool, "name", "bad/name") end)
          ),
          update_in(
            config,
            ["tools"],
            &Enum.map(&1, fn tool -> Map.put(tool, "title", String.duplicate("é", 129)) end)
          )
        ]

    for value <- variants do
      File.write!(path, Jason.encode!(value))
      assert {:error, :config_invalid} = PtcGateway.start_link(path)
    end
  end

  @tag :nightly
  @tag :tmp_dir
  test "CLI emits only the closed stderr error and exits 78", %{tmp_dir: dir} do
    stdout = Path.join(dir, "stdout")
    stderr = Path.join(dir, "stderr")

    {"", 78} =
      System.cmd(
        "sh",
        [
          "-c",
          ~S(exec "$1" ptc.gateway "$2" >"$3" 2>"$4"),
          "--",
          System.find_executable("mix"),
          Path.join(dir, "missing.json"),
          stdout,
          stderr
        ],
        env: [{"MIX_ENV", "test"}]
      )

    assert File.read!(stdout) == ""
    assert File.read!(stderr) == "{\"error\":\"config_unavailable\"}\n"
  end

  @tag :tmp_dir
  test "IPv6 loopback uses its exact bracketed authority", %{tmp_dir: dir} do
    {path, config} = fixture(dir)
    {:ok, socket} = :gen_tcp.listen(0, [:inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    config = put_in(config, ["listen", "address"], "::1") |> put_in(["listen", "port"], port)
    File.write!(path, Jason.encode!(config))
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(owner) end)

    response =
      Req.get!("http://[::1]:#{port}/health/ready",
        retry: false,
        headers: [{"host", "[::1]:#{port}"}]
      )

    assert response.status == 200
    assert response.body == %{"status" => "ready"}
  end

  @tag :tmp_dir
  test "nested credential files stay relative to the host document", %{tmp_dir: dir} do
    {path, config} = fixture(Path.join(dir, "gateway"))
    host_dir = Path.join(dir, "gateway/host")
    File.mkdir_p!(host_dir)
    File.write!(Path.join(host_dir, "token"), @token)

    File.write!(
      Path.join(host_dir, "host.json"),
      Jason.encode!(%{
        "credentials" => %{"gateway" => %{"file" => "token"}},
        "install" => %{}
      })
    )

    config = put_in(config, ["host", "path"], "host/host.json")
    File.write!(path, Jason.encode!(config))

    File.cd!(dir, fn ->
      assert {:ok, owner} = PtcGateway.start_link(path)
      on_exit(fn -> stop(owner) end)

      assert WarmProviderRuntime.authenticate(
               PtcGateway.Domain.token_handle(owner),
               @token
             )

      assert response(config, "/health/ready").status == 200
    end)
  end

  @tag :tmp_dir
  test "MCP discovery and listing are authenticated, strict, and deterministic", %{tmp_dir: dir} do
    {path, config} = fixture(dir)
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(owner) end)

    discover = mcp(config, "server/discover", "request-id")
    assert discover.status == 200
    assert discover.headers["cache-control"] == ["no-store"]
    assert discover.body["id"] == "request-id"

    assert discover.body["result"] == %{
             "resultType" => "complete",
             "supportedVersions" => ["2026-07-28"],
             "capabilities" => %{"tools" => %{"listChanged" => false}},
             "ttlMs" => 0,
             "cacheScope" => "private"
           }

    listing =
      mcp(config, "tools/list", -9,
        headers: [{"mcp-session-id", "ignored"}, {"last-event-id", "ignored"}]
      )

    assert listing.status == 200
    assert listing.body["id"] == -9
    assert Enum.map(listing.body["result"]["tools"], & &1["name"]) == ["a", "z"]

    assert Enum.all?(listing.body["result"]["tools"], fn tool ->
             Map.keys(tool) |> Enum.sort() ==
               Enum.sort(~w(annotations description inputSchema name outputSchema title)) and
               tool["annotations"] == %{"readOnlyHint" => true}
           end)

    assert mcp(config, "tools/list", 1, params: %{"cursor" => "x"}).body["error"]["code"] ==
             -32602

    assert mcp(config, "resources/list", 1).status == 404
    assert mcp(config, "resources/list", 1).body["error"]["code"] == -32601

    unauthorized =
      mcp(config, "server/discover", 1,
        token: "wrong-token-that-is-long-enough-123",
        raw_body: "not-json"
      )

    assert unauthorized.status == 401
    assert unauthorized.headers["www-authenticate"] == ["Bearer"]
    refute inspect(unauthorized) =~ "not-json"

    assert mcp(config, "server/discover", 1, accept: "application/json").status == 406
    assert mcp(config, "server/discover", 1, content_type: "text/plain").status == 415
    assert response(config, "/mcp", method: :get).status == 405

    mismatch = mcp(config, "server/discover", 1, protocol: "2025-11-25")
    assert mismatch.status == 400
    assert mismatch.body["error"]["code"] == -32022

    malformed = mcp(config, "server/discover", 1, raw_body: "{")
    assert malformed.status == 400
    assert malformed.body["error"]["code"] == -32700
    refute Map.has_key?(malformed.body, "id")
  end

  @tag :tmp_dir
  test "a literal bearer credential refuses startup", %{tmp_dir: dir} do
    {path, config} = fixture(dir)

    File.write!(
      Path.join(dir, "host.json"),
      Jason.encode!(%{
        "credentials" => %{"gateway" => %{"literal" => @token}},
        "install" => %{}
      })
    )

    File.write!(path, Jason.encode!(config))
    assert {:error, :credential_unavailable} = PtcGateway.start_link(path)
  end

  @tag :tmp_dir
  test "rotation prunes down to a narrowed retention bound, oldest first", %{tmp_dir: dir} do
    config = %{
      "directory" => Path.join(dir, "audit"),
      "max_file_bytes" => 1024,
      "max_retained_files" => 2
    }

    wide = %{config | "max_retained_files" => 8}

    for _ <- 1..4 do
      assert {:ok, owner} = PtcGateway.PrivateAudit.start_link(wide)
      GenServer.stop(owner)
    end

    assert length(File.ls!(config["directory"])) == 4
    [oldest, next | _] = Enum.sort(File.ls!(config["directory"]))

    # The next startup opens its replacement and then prunes to the narrowed
    # bound: the deletion the bound asks for, taking the oldest files first.
    assert {:ok, owner} = PtcGateway.PrivateAudit.start_link(config)
    GenServer.stop(owner)
    kept = Enum.sort(File.ls!(config["directory"]))
    assert length(kept) == 2
    refute oldest in kept
    refute next in kept
  end

  defp fixture(dir, effect \\ :read) do
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "workflow.clj"),
      "(ns app) (defn run {:effect :#{effect}} [input] (return input))"
    )

    File.write!(Path.join(dir, "schema.json"), Jason.encode!(%{"type" => "object"}))

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "workflow.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"path" => "missing.json"},
      "contracts" => %{
        "input_schema" => %{"path" => "schema.json"},
        "result_schema" => %{"path" => "schema.json"}
      }
    }

    manifest_path = Path.join(dir, "app.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    {:ok, template} = ServingTemplate.from_directory(manifest_path, Limits.installed_defaults())

    File.write!(
      Path.join(dir, "host.json"),
      Jason.encode!(%{
        "credentials" => %{"gateway" => %{"env" => "GATEWAY_TEST_TOKEN"}},
        "install" => %{}
      })
    )

    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    tool = %{
      "name" => "a",
      "title" => "A",
      "description" => "A tool",
      "application" => %{"manifest" => "app.json"},
      "expected_application_content_digest" =>
        ServingTemplate.application_content_digest(template),
      "installation_config_pins" => %{},
      "provider_snapshot_pins" => %{}
    }

    config = %{
      "version" => 1,
      "listen" => %{"address" => "127.0.0.1", "port" => port, "path" => "/mcp"},
      "authentication" => %{"bearer" => %{"binding" => "gateway"}},
      "host" => %{"path" => "host.json"},
      "admission" => %{
        "max_inflight_requests" => 16,
        "max_concurrent_runs" => 4,
        "max_active_provider_calls" => 4,
        "max_waiting_provider_calls" => 0
      },
      "tools" => [Map.put(tool, "name", "z"), tool]
    }

    path = Path.join(dir, "gateway.json")
    File.write!(path, Jason.encode!(config))
    {path, config}
  end

  defp response(config, path, opts \\ []) do
    Req.request!(
      [url: "http://127.0.0.1:#{config["listen"]["port"]}#{path}", retry: false] ++ opts
    )
  end

  defp mcp(config, method, id, opts \\ []) do
    protocol = Keyword.get(opts, :protocol, "2026-07-28")

    params =
      Map.merge(
        %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => protocol,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        },
        Keyword.get(opts, :params, %{})
      )

    body =
      Keyword.get_lazy(opts, :raw_body, fn ->
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
      end)

    headers = [
      {"authorization", "Bearer #{Keyword.get(opts, :token, @token)}"},
      {"content-type", Keyword.get(opts, :content_type, "application/json")},
      {"accept", Keyword.get(opts, :accept, "application/json, text/event-stream")},
      {"mcp-protocol-version", protocol},
      {"mcp-method", method}
    ]

    response(config, "/mcp",
      method: :post,
      headers: headers ++ Keyword.get(opts, :headers, []),
      body: body
    )
  end

  defp stop(pid), do: if(Process.alive?(pid), do: GenServer.stop(pid))
end
