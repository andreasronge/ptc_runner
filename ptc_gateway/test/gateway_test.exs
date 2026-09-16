defmodule PtcGatewayTest do
  use ExUnit.Case, async: false
  import PtcGateway.TestSupport.GatewayFixture
  alias PtcRunner.Kernel.{GatewayConfig, Limits, ServingTemplate, WarmProviderRuntime}

  @token PtcGateway.TestSupport.GatewayFixture.token()
  @authority_uid 4_294_967_294
  @foreign_uid 65_534
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
  test "idle staged shutdown proves clean admission and provider cleanup", %{tmp_dir: dir} do
    {path, _config} = fixture(dir)
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    assert :ok = PtcGateway.Domain.shutdown(owner, 100, 1_000)
    refute Process.alive?(owner)
  end

  @tag :tmp_dir
  test "staged shutdown never clears an earlier admission fence", %{tmp_dir: dir} do
    {path, _config} = fixture(dir)
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    run_admission = :sys.get_state(owner).run_admission
    assert :ok = PtcRunner.Kernel.RunAdmission.cancel_all(run_admission)
    assert {:error, :uncertain_cleanup} = PtcGateway.Domain.shutdown(owner, 100, 1_000)
    refute Process.alive?(owner)
  end

  @tag :tmp_dir
  test "unexpected listener exit is an unsuccessful domain exit", %{tmp_dir: dir} do
    {path, _config} = fixture(dir)
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    Process.unlink(owner)
    monitor = Process.monitor(owner)
    listener = :sys.get_state(owner).listener
    Process.exit(listener, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :gateway_listener_failed}, 2_000
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

  test "private audit resolves safe ancestors and creates missing nested directories" do
    root = Path.join(System.tmp_dir!(), "ptc-gateway-audit-#{System.unique_integer([:positive])}")
    target = Path.join(root, "target")
    linked = Path.join(root, "linked")
    directory = Path.join([linked, "missing", "audit"])
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(target)
    File.chmod!(target, 0o700)
    File.ln_s!(target, linked)

    assert {:ok, owner} = PtcGateway.PrivateAudit.start_link(audit_config(directory))
    GenServer.stop(owner)
    assert Bitwise.band(File.stat!(Path.join(target, "missing")).mode, 0o777) == 0o700
    assert Bitwise.band(File.stat!(directory).mode, 0o777) == 0o700
  end

  @tag :tmp_dir
  test "private audit delegates unsafe ancestor ownership and modes", %{tmp_dir: dir} do
    replaceable = Path.join(dir, "replaceable")
    File.mkdir!(replaceable)
    File.chmod!(replaceable, 0o777)

    assert {:error, :audit_unavailable} =
             PtcGateway.PrivateAudit.start_link(audit_config(Path.join(replaceable, "audit")))

    bin = Path.join(dir, "authority-bin")
    id = Path.join(bin, "id")
    foreign = Path.join(dir, "foreign")
    original_path = System.fetch_env!("PATH")
    File.mkdir!(bin)
    File.mkdir!(foreign)

    if File.stat!(foreign, time: :posix).uid == 0,
      do: :ok = File.chown(foreign, @foreign_uid)

    File.ln_s!(System.find_executable("mkdir"), Path.join(bin, "mkdir"))
    File.write!(id, "#!/bin/sh\nprintf '#{@authority_uid}\\n'\n")
    File.chmod!(id, 0o700)
    System.put_env("PATH", bin)
    on_exit(fn -> System.put_env("PATH", original_path) end)

    assert {:error, :audit_unavailable} =
             PtcGateway.PrivateAudit.start_link(audit_config(Path.join(foreign, "audit")))
  end

  @tag :tmp_dir
  test "private audit rotates full active files before durable append", %{tmp_dir: dir} do
    config = %{
      "directory" => Path.join(dir, "audit"),
      "max_file_bytes" => 1024,
      "max_retained_files" => 2
    }

    assert {:ok, owner} = PtcGateway.PrivateAudit.start_link(config)

    for index <- 1..10 do
      assert :ok = PtcGateway.PrivateAudit.append(owner, audit_record(index))
    end

    GenServer.stop(owner)

    files =
      config["directory"]
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.sort()

    assert length(files) == 2

    records =
      files
      |> Enum.flat_map(fn file ->
        Path.join(config["directory"], file) |> File.read!() |> String.split("\n", trim: true)
      end)

    assert length(records) in 2..6
    assert records |> List.last() |> Jason.decode!() |> Map.fetch!("call_id") == "call-10"
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
    audit_ref = Process.monitor(audit)
    owner_ref = Process.monitor(owner)
    Process.exit(audit, :kill)
    assert_receive {:DOWN, ^audit_ref, :process, ^audit, :killed}
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :gateway_child_failed}
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
          Map.put(config, "tools", List.duplicate(hd(config["tools"]), 129)),
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

  @tag :tmp_dir
  test "invalid MCP header annotations refuse readiness", %{tmp_dir: dir} do
    {path, config} = fixture(dir)
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")

    invalid = %{
      "type" => "object",
      "properties" => %{
        "nested" => %{
          "type" => "object",
          "x-mcp-header" => "Nested"
        }
      }
    }

    _config = rewrite_schema_config(path, config, invalid, 2)
    assert {:error, :template_invalid} = PtcGateway.start_link(path, env_file: env)
  end

  @tag :tmp_dir
  test "private event policy wins before a stale content digest", %{tmp_dir: dir} do
    {path, config} = fixture(dir)
    manifest_path = Path.join(dir, "app.json")

    manifest_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("events", %{"policy" => "private"})
    |> then(&File.write!(manifest_path, Jason.encode!(&1)))

    File.write!(path, Jason.encode!(config))
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:error, :template_invalid} = PtcGateway.start_link(path, env_file: env)
  end

  @tag :slow
  @tag :tmp_dir
  test "normalized schema, static catalog, and encoded response ceilings refuse startup", %{
    tmp_dir: dir
  } do
    {path, config} = fixture(dir)
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")

    exact_schema = sized_schema(65_536)
    assert {:ok, exact_normalized, _compiled} = PtcRunner.Kernel.JSONSchema.compile(exact_schema)
    assert deterministic_size(exact_normalized) == 65_536
    exact_config = rewrite_schema_config(path, config, exact_schema, 2)
    assert {:ok, exact_owner} = PtcGateway.start_link(path, env_file: env)
    stop(exact_owner)

    oversized_schema = Map.update!(exact_schema, "description", &(&1 <> "x"))

    assert {:error, {:invalid_schema, %{rule: :schema_too_large}}} =
             PtcRunner.Kernel.JSONSchema.compile(oversized_schema)

    File.write!(Path.join(dir, "schema.json"), Jason.encode!(oversized_schema))
    File.write!(path, Jason.encode!(exact_config))
    assert {:error, :template_invalid} = PtcGateway.start_link(path, env_file: env)

    exact_response = sized_static_config(path, config, 4_194_304, :response)
    assert {:ok, catalog_owner} = PtcGateway.start_link(path, env_file: env)
    listing = mcp(exact_response, "tools/list", String.duplicate(<<0>>, 256))
    assert listing.status == 200
    assert deterministic_size(listing.body) == 4_194_304
    stop(catalog_owner)

    _over_response = sized_static_config(path, config, 4_194_305, :response)
    assert {:error, :catalog_too_large} = PtcGateway.start_link(path, env_file: env)

    exact_catalog = sized_static_tools(4_194_304, :catalog)
    assert deterministic_size(exact_catalog) == 4_194_304
    assert PtcGateway.Domain.within_static_limit?(exact_catalog)

    over_catalog = sized_static_tools(4_194_305, :catalog)
    assert deterministic_size(over_catalog) == 4_194_305
    refute PtcGateway.Domain.within_static_limit?(over_catalog)
  end

  @tag :slow
  @tag :tmp_dir
  test "exactly 128 unique tools start and list successfully", %{tmp_dir: dir} do
    {path, config} = fixture(dir)
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    exact_config = rewrite_schema_config(path, config, %{"type" => "object"}, 128)

    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(owner) end)
    listing = mcp(exact_config, "tools/list", 1)
    assert listing.status == 200
    assert length(listing.body["result"]["tools"]) == 128
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

    assert mcp(config, "server/discover", 1,
             accept: "*/*;q=1, application/json;q=0, text/event-stream;q=1"
           ).status == 406

    assert mcp(config, "server/discover", 1, accept: "*/json, text/event-stream").status ==
             406

    assert mcp(config, "server/discover", 1, accept: "application/json;q, text/event-stream").status ==
             406

    assert mcp(config, "server/discover", 1,
             accept: "application/json;charset=latin1, text/event-stream"
           ).status == 406

    assert mcp(config, "server/discover", 1,
             accept: ~s(application/json;charset="utf-8", text/event-stream)
           ).status == 200

    assert mcp(config, "server/discover", 1,
             accept: ~s(application/json;foo="a,b", application/json, text/event-stream)
           ).status == 200

    assert mcp(config, "server/discover", 1, content_type: "text/plain").status == 415
    assert response(config, "/mcp", method: :get).status == 405

    mismatch = mcp(config, "server/discover", 1, protocol: "2025-11-25")
    assert mismatch.status == 400
    assert mismatch.body["error"]["code"] == -32022

    malformed = mcp(config, "server/discover", 1, raw_body: "{")
    assert malformed.status == 400
    assert malformed.body["error"]["code"] == -32700
    refute Map.has_key?(malformed.body, "id")

    invalid_info = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{},
        "io.modelcontextprotocol/clientInfo" => %{
          "name" => "client",
          "version" => "1",
          "icons" => 42
        }
      }
    }

    invalid_info_response = mcp(config, "server/discover", 1, full_params: invalid_info)
    assert invalid_info_response.status == 400
    assert invalid_info_response.body["error"]["code"] == -32602

    invalid_info =
      put_in(
        invalid_info,
        ["_meta", "io.modelcontextprotocol/clientInfo"],
        %{"name" => "client", "version" => "1", "websiteUrl" => "http://exa mple.com"}
      )

    invalid_uri_response = mcp(config, "server/discover", 1, full_params: invalid_info)
    assert invalid_uri_response.status == 400
    assert invalid_uri_response.body["error"]["code"] == -32602

    for invalid_uri <- ["http://example.com/%", "http://exa%ZZmple"] do
      invalid_info =
        put_in(
          invalid_info,
          ["_meta", "io.modelcontextprotocol/clientInfo", "websiteUrl"],
          invalid_uri
        )

      response = mcp(config, "server/discover", 1, full_params: invalid_info)
      assert response.status == 400
      assert response.body["error"]["code"] == -32602
    end

    for valid_uri <- ["HTTP://example.com/path", "http://example.com:80"] do
      valid_info =
        put_in(
          invalid_info,
          ["_meta", "io.modelcontextprotocol/clientInfo", "websiteUrl"],
          valid_uri
        )

      response = mcp(config, "server/discover", 1, full_params: valid_info)
      assert response.status == 200
      refute Map.has_key?(response.body, "error")
    end
  end

  @tag :tmp_dir
  test "tools/call commits SSE and executes the selected template", %{tmp_dir: dir} do
    {path, config} = fixture(dir)
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(owner) end)

    call =
      mcp(config, "tools/call", 7,
        params: %{"name" => "a", "arguments" => %{}},
        headers: [{"mcp-name", "a"}]
      )

    assert call.status == 200, inspect(call)
    assert ["text/event-stream; charset=utf-8"] = call.headers["content-type"]
    assert call.headers["mcp-protocol-version"] == ["2026-07-28"]
    assert [_, event, ""] = String.split(call.body, "\n\n")
    assert ["event: message", payload] = String.split(event, "\n")
    assert "data: " <> json = payload
    assert %{"id" => 7, "result" => result} = Jason.decode!(json)
    assert result["resultType"] == "complete"
    assert result["structuredContent"] == %{}
    assert result["content"] == [%{"type" => "text", "text" => ~s({})}]
    assert result["isError"] == false

    mismatch =
      mcp(config, "tools/call", 8,
        params: %{"name" => "a"},
        headers: [{"mcp-name", "z"}]
      )

    assert mismatch.status == 400
    assert mismatch.body["error"]["code"] == -32020

    invalid =
      mcp(config, "tools/call", 9,
        params: %{"name" => "a", "requestState" => "forbidden"},
        headers: [{"mcp-name", "a"}]
      )

    assert invalid.body["error"]["code"] == -32602

    unknown =
      mcp(config, "tools/call", 10,
        params: %{"name" => "missing"},
        headers: [{"mcp-name", "missing"}]
      )

    assert unknown.status == 200
    assert unknown.body["error"]["code"] == -32602
  end

  @tag :tmp_dir
  test "a dispatched write durably appends the bounded private audit record", %{tmp_dir: dir} do
    {path, config} = fixture(dir, :write)
    audit_dir = Path.join(dir, "audit")

    config =
      config
      |> Map.put("private_audit", %{
        "directory" => "audit",
        "max_file_bytes" => 4096,
        "max_retained_files" => 2
      })
      |> update_in(["tools"], &Enum.map(&1, fn tool -> Map.put(tool, "allow_write", true) end))

    File.write!(path, Jason.encode!(config))
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(owner) end)
    run_admission = :sys.get_state(owner).run_admission

    assert mcp(config, "tools/call", 10,
             params: %{"name" => "a"},
             headers: [{"mcp-name", "a"}]
           ).status == 200

    assert :ok = await_run_release(run_admission, 100)

    [file] = audit_dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
    [line] = Path.join(audit_dir, file) |> File.read!() |> String.split("\n", trim: true)
    record = Jason.decode!(line)
    assert record["tool_name"] == "a"
    assert record["outcome_code"] == "success"
    assert record["dispatch_state"] == "true"
    assert record["write_effects_may_have_occurred"] == true

    assert Map.keys(record) |> Enum.sort() ==
             Enum.sort(
               ~w(call_id cleanup_status disconnected dispatch_state ended_at outcome_code started_at tool_name write_effects_may_have_occurred)
             )
  end

  @tag :tmp_dir
  @tag timeout: 30_000
  test "loopback disconnect survives the request and retains admission through audit", %{
    tmp_dir: dir
  } do
    {path, config} = fixture(dir, :write)

    config =
      config
      |> put_in(["admission", "max_concurrent_runs"], 1)
      |> Map.put("private_audit", %{
        "directory" => "audit",
        "max_file_bytes" => 4096,
        "max_retained_files" => 2
      })
      |> update_in(["tools"], &Enum.map(&1, fn tool -> Map.put(tool, "allow_write", true) end))

    File.write!(path, Jason.encode!(config))
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(owner) end)
    state = :sys.get_state(owner)
    parent = self()

    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    listen = %{config["listen"] | "port" => port}

    assert {:ok, listener} =
             Bandit.start_link(
               plug:
                 {PtcGateway.Router,
                  listen: listen,
                  warm: state.warm,
                  tools: state.metadata,
                  tool_entries: state.tools,
                  run_admission: state.run_admission,
                  audit: state.audit,
                  request_admission: state.request_admission,
                  serving_hooks: %{
                    after_activation: fn _execution ->
                      send(parent, {:activated, self()})
                      receive do: (:release_execution -> :ok)
                    end,
                    before_audit: fn outcome, disconnected ->
                      send(parent, {:audit_waiting, self(), outcome, disconnected})
                      receive do: (:release_audit -> :ok)
                    end
                  }},
               ip: {127, 0, 0, 1},
               port: port,
               startup_log: false,
               http_2_options: [enabled: false]
             )

    on_exit(fn -> stop(listener) end)
    body = call_body("a", %{})

    request = [
      "POST /mcp HTTP/1.1\r\n",
      "Host: 127.0.0.1:#{port}\r\n",
      "Authorization: Bearer #{@token}\r\n",
      "Content-Type: application/json\r\n",
      "Accept: application/json, text/event-stream\r\n",
      "MCP-Protocol-Version: 2026-07-28\r\n",
      "Mcp-Method: tools/call\r\n",
      "Mcp-Name: a\r\n",
      "Content-Length: #{byte_size(body)}\r\n\r\n",
      body
    ]

    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(client, request)
    assert_receive {:activated, worker}, 2_000
    :ok = :gen_tcp.close(client)
    assert {:ok, %{in_use: 1}} = PtcRunner.Kernel.RunAdmission.snapshot(state.run_admission)

    # The five-second heartbeat observes the closed loopback socket. Execution
    # remains deliberately held until after that cancellation bound.
    receive do
    after
      5_500 -> :ok
    end

    send(worker, :release_execution)
    assert_receive {:audit_waiting, audit_worker, outcome, true}, 10_000
    assert PtcRunner.Kernel.ServingOutcome.code(outcome) == :cancelled
    assert {:ok, %{in_use: 1}} = PtcRunner.Kernel.RunAdmission.snapshot(state.run_admission)

    busy =
      mcp(config, "tools/call", 12,
        params: %{"name" => "a"},
        headers: [{"mcp-name", "a"}]
      )

    assert busy.status == 429
    send(audit_worker, :release_audit)
    assert :ok = await_run_release(state.run_admission, 100)

    [record | _] =
      Path.join(dir, "audit")
      |> Path.join("*.jsonl")
      |> Path.wildcard()
      |> Enum.flat_map(fn audit ->
        audit |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      end)

    assert record["disconnected"] == true
    assert record["outcome_code"] == "cancelled"
  end

  @tag :tmp_dir
  @tag timeout: 30_000
  test "sequential tools/call is refused by run admission while prior cleanup is held", %{
    tmp_dir: dir
  } do
    {path, config} = fixture(dir)
    config = put_in(config, ["admission", "max_concurrent_runs"], 1)
    File.write!(path, Jason.encode!(config))
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(owner) end)
    state = :sys.get_state(owner)
    parent = self()

    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    listen = %{config["listen"] | "port" => port}
    config = put_in(config, ["listen", "port"], port)

    assert {:ok, listener} =
             Bandit.start_link(
               plug:
                 {PtcGateway.Router,
                  listen: listen,
                  warm: state.warm,
                  tools: state.metadata,
                  tool_entries: state.tools,
                  run_admission: state.run_admission,
                  audit: state.audit,
                  request_admission: state.request_admission,
                  serving_hooks: %{
                    before_audit: fn outcome, disconnected ->
                      send(parent, {:audit_waiting, self(), outcome, disconnected})
                      receive do: (:release_audit -> :ok)
                    end
                  }},
               ip: {127, 0, 0, 1},
               port: port,
               startup_log: false,
               http_2_options: [enabled: false]
             )

    on_exit(fn -> stop(listener) end)

    first =
      mcp(config, "tools/call", 20,
        params: %{"name" => "a", "arguments" => %{}},
        headers: [{"mcp-name", "a"}]
      )

    assert first.status == 200, inspect(first)
    assert_receive {:audit_waiting, audit_worker, outcome, false}, 2_000
    assert PtcRunner.Kernel.ServingOutcome.code(outcome) == :success
    assert {:ok, %{in_use: 1}} = PtcRunner.Kernel.RunAdmission.snapshot(state.run_admission)

    request = :sys.get_state(state.request_admission)
    assert map_size(request.leases) < request.maximum

    busy =
      mcp(config, "tools/call", 21,
        params: %{"name" => "a", "arguments" => %{}},
        headers: [{"mcp-name", "a"}]
      )

    assert busy.status == 429

    assert busy.body == %{
             "jsonrpc" => "2.0",
             "id" => 21,
             "error" => %{"code" => -31999, "message" => "Server busy"}
           }

    assert {:ok, %{in_use: 1}} = PtcRunner.Kernel.RunAdmission.snapshot(state.run_admission)
    send(audit_worker, :release_audit)
    assert :ok = await_run_release(state.run_admission, 100)
  end

  @tag :tmp_dir
  test "MCP critical headers and aggregate header bounds are enforced", %{tmp_dir: dir} do
    {path, config} = fixture(dir)

    config =
      put_in(config, ["listen", "allowed_origins"], ["https://one.example", "https://two.example"])

    File.write!(path, Jason.encode!(config))
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(owner) end)

    duplicate_cases = [
      {"origin", "https://one.example", 403},
      {"authorization", "Bearer #{@token}", 401},
      {"content-type", "application/json", 415},
      {"accept", "application/json, text/event-stream", 406},
      {"mcp-protocol-version", "2026-07-28", 400},
      {"mcp-method", "tools/list", 400},
      {"mcp-name", "a", 400}
    ]

    assert raw_mcp_status(config, [
             {"Host", "127.0.0.1:#{config["listen"]["port"]}"},
             {"Host", "127.0.0.1:#{config["listen"]["port"]}"}
           ]) == 400

    assert raw_mcp_status(config, [{"Host", "evil.example"}]) == 400

    for {name, value, status} <- duplicate_cases do
      headers =
        cond do
          name == "origin" -> [{"origin", value}, {"origin", "https://two.example"}]
          name == "mcp-name" -> [{name, value}, {name, value}]
          true -> [{name, value}]
        end

      assert mcp(config, "tools/list", 1, headers: headers).status == status,
             "duplicate #{name} was not rejected"
    end

    assert raw_mcp_status(config, [{"Mcp-Method", "TOOLS/LIST"}]) == 400
    assert raw_mcp_status(config, [{"mcp-method", "tools/list"}]) == 200
    assert raw_mcp_status(config, [{"MCP-METHOD", "tools/list"}]) == 200
    assert raw_mcp_status(config, [{"Mcp-Method", " \ttools/list\t "}]) == 200
    assert raw_status(raw_mcp_response(config, [], method_header: false)) == 400

    tab_bearer = raw_mcp_response(config, [{"Authorization", "Bearer\t#{@token}"}])
    assert raw_status(tab_bearer) == 401

    exact_count_headers = for index <- 1..56, do: {"X-Count-#{index}", "x"}
    assert raw_status(raw_mcp_response(config, exact_count_headers)) == 200

    count_error = raw_mcp_response(config, [{"X-Count-57", "x"} | exact_count_headers])
    assert raw_status(count_error) == 431
    assert raw_body(count_error) == ""

    exact_aggregate_headers = aggregate_padding_headers(config, 32_768)
    assert raw_status(raw_mcp_response(config, exact_aggregate_headers)) == 200

    [{name, value} | rest] = exact_aggregate_headers
    aggregate_error = raw_mcp_response(config, [{name, value <> "x"} | rest])
    assert raw_status(aggregate_error) == 431
    assert raw_body(aggregate_error) == ~s({"error":"request_headers_too_large"})

    exact_line = raw_mcp_response(config, [{"X-Line", String.duplicate("x", 8_182)}])
    assert raw_status(exact_line) == 200

    oversized_line = raw_mcp_response(config, [{"X-Line", String.duplicate("x", 8_183)}])
    assert raw_status(oversized_line) == 431
    assert raw_body(oversized_line) == ""

    assert raw_status(
             raw_mcp_response(config, [], request_target: "/" <> String.duplicate("x", 8_175))
           ) ==
             404

    request_line_error =
      raw_mcp_response(config, [], request_target: "/" <> String.duplicate("x", 8_176))

    assert raw_status(request_line_error) == 414
    assert raw_body(request_line_error) == ""
  end

  @tag :tmp_dir
  test "MCP body, metadata, JSON, and ID ceilings accept the boundary only", %{tmp_dir: dir} do
    {path, config} = fixture(dir)
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(owner) end)

    exact_body = sized_json_object(2_097_152)
    assert byte_size(exact_body) == 2_097_152
    assert mcp(config, "tools/list", 1, raw_body: exact_body).body["error"]["code"] == -32600

    oversized_body = exact_body <> " "
    body_error = mcp(config, "tools/list", 1, raw_body: oversized_body)
    assert body_error.status == 413
    assert body_error.body == %{"error" => "request_too_large"}
    assert byte_size(Jason.encode!(body_error.body)) <= 128

    exact_meta = sized_meta(65_536)
    assert byte_size(Jason.encode!(exact_meta)) == 65_536

    refute Map.has_key?(
             mcp(config, "server/discover", 1, full_params: %{"_meta" => exact_meta}).body,
             "error"
           )

    oversized_meta = Map.update!(exact_meta, "padding", &(&1 <> "x"))
    meta_error = mcp(config, "server/discover", 1, full_params: %{"_meta" => oversized_meta})
    assert meta_error.status == 400
    assert meta_error.body["error"]["code"] == -32602

    exact_depth = Jason.encode!(%{"padding" => nest_json(62)})

    assert {:ok, _} =
             PtcRunner.Kernel.StrictJSON.decode(exact_depth, max_depth: 64, max_nodes: 100_000)

    assert mcp(config, "tools/list", 1, raw_body: exact_depth).body["error"]["code"] == -32600

    excessive_depth = Jason.encode!(%{"padding" => nest_json(63)})
    assert mcp(config, "tools/list", 1, raw_body: excessive_depth).body["error"]["code"] == -32700

    exact_nodes = Jason.encode!(%{"padding" => List.duplicate(0, 99_997)})

    assert {:ok, _} =
             PtcRunner.Kernel.StrictJSON.decode(exact_nodes, max_depth: 64, max_nodes: 100_000)

    assert mcp(config, "tools/list", 1, raw_body: exact_nodes).body["error"]["code"] == -32600

    excessive_nodes = Jason.encode!(%{"padding" => List.duplicate(0, 99_998)})
    assert mcp(config, "tools/list", 1, raw_body: excessive_nodes).body["error"]["code"] == -32700

    for id <- [String.duplicate("x", 256), -9_007_199_254_740_991, 9_007_199_254_740_991] do
      assert mcp(config, "server/discover", id).body["id"] == id
    end

    for id <- [String.duplicate("x", 257), -9_007_199_254_740_992, 9_007_199_254_740_992] do
      response = mcp(config, "server/discover", id)
      assert response.body["error"]["code"] == -32600
      refute Map.has_key?(response.body, "id")
    end
  end

  test "request admission atomically bounds active requests" do
    assert {:ok, admission} = PtcGateway.RequestAdmission.start_link(1)
    assert {:ok, lease} = PtcGateway.RequestAdmission.acquire(admission)
    assert :full = PtcGateway.RequestAdmission.acquire(admission)
    assert :ok = PtcGateway.RequestAdmission.release(admission, lease)
    assert {:ok, _lease} = PtcGateway.RequestAdmission.acquire(admission)

    assert {:ok, reclaiming} = PtcGateway.RequestAdmission.start_link(1)
    parent = self()

    holder =
      spawn(fn ->
        send(parent, {:held, PtcGateway.RequestAdmission.acquire(reclaiming)})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:held, {:ok, _lease}}
    monitor = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}
    assert {:ok, _lease} = acquire_eventually(reclaiming, 100)
  end

  @tag :tmp_dir
  test "full HTTP admission returns the reserved-range-safe busy code", %{tmp_dir: dir} do
    {path, config} = fixture(dir)
    config = put_in(config, ["admission", "max_inflight_requests"], 1)
    File.write!(path, Jason.encode!(config))
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(owner) end)
    admission = :sys.get_state(owner).request_admission
    assert {:ok, lease} = PtcGateway.RequestAdmission.acquire(admission)
    on_exit(fn -> PtcGateway.RequestAdmission.release(admission, lease) end)

    busy = mcp(config, "tools/list", 7)
    assert busy.status == 429

    assert busy.body == %{
             "jsonrpc" => "2.0",
             "error" => %{"code" => -31999, "message" => "Server busy"}
           }
  end

  @tag :tmp_dir
  test "unavailable HTTP admission rejects before body parsing without an ID", %{tmp_dir: dir} do
    {path, config} = fixture(dir)
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(owner) end)
    admission = :sys.get_state(owner).request_admission
    monitor = Process.monitor(admission)
    Process.exit(admission, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^admission, :killed}
    _ = PtcGateway.Domain.metadata(owner)

    response = raw_mcp_response(config, [], body: "not-json")
    assert raw_status(response) == 503

    assert Jason.decode!(raw_body(response)) == %{
             "jsonrpc" => "2.0",
             "error" => %{"code" => -31998, "message" => "Server unavailable"}
           }
  end

  @tag :nightly
  @tag :tmp_dir
  test "official MCP conformance tools and header subset", %{tmp_dir: dir} do
    {path, config} = fixture(dir)

    schema = %{
      "type" => "object",
      "properties" => %{"query" => %{"type" => "string", "x-mcp-header" => "Query"}},
      "required" => ["query"]
    }

    File.write!(Path.join(dir, "schema.json"), Jason.encode!(schema))

    {:ok, template} =
      ServingTemplate.from_directory(Path.join(dir, "app.json"), Limits.installed_defaults())

    config =
      update_in(config, ["tools"], fn tools ->
        Enum.map(tools, fn tool ->
          Map.put(
            tool,
            "expected_application_content_digest",
            ServingTemplate.application_content_digest(template)
          )
        end)
      end)

    write_dir = Path.join(dir, "write-app")
    File.mkdir_p!(write_dir)

    File.write!(
      Path.join(write_dir, "workflow.clj"),
      "(ns app) (defn run {:effect :write} [input] (return input))"
    )

    File.write!(Path.join(write_dir, "schema.json"), Jason.encode!(schema))
    write_manifest = Path.join(write_dir, "app.json")

    File.write!(
      write_manifest,
      Jason.encode!(%{
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
      })
    )

    {:ok, write_template} =
      ServingTemplate.from_directory(write_manifest, Limits.installed_defaults())

    write_tool =
      hd(config["tools"])
      |> Map.put("name", "write")
      |> Map.put("title", "Write")
      |> Map.put("application", %{"manifest" => "write-app/app.json"})
      |> Map.put(
        "expected_application_content_digest",
        ServingTemplate.application_content_digest(write_template)
      )
      |> Map.put("allow_write", true)

    config =
      config
      |> Map.put("tools", config["tools"] ++ [write_tool])
      |> Map.put("private_audit", %{
        "directory" => "audit",
        "max_file_bytes" => 4096,
        "max_retained_files" => 2
      })

    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, proxy_port} = :inet.port(socket)
    :gen_tcp.close(socket)
    proxy_authority = "127.0.0.1:#{proxy_port}"
    config = put_in(config, ["listen", "allowed_origins"], ["http://#{proxy_authority}"])
    File.write!(path, Jason.encode!(config))
    env = Path.join(dir, "credentials.env")
    File.write!(env, "GATEWAY_TEST_TOKEN=#{@token}\n")
    assert {:ok, owner} = PtcGateway.start_link(path, env_file: env)
    on_exit(fn -> stop(owner) end)

    assert get_in(PtcGateway.Domain.metadata(owner), [
             :tools,
             Access.at(0),
             "inputSchema",
             "properties",
             "query",
             "x-mcp-header"
           ]) == "Query"

    target_authority = "127.0.0.1:#{config["listen"]["port"]}"

    assert {:ok, proxy} =
             Bandit.start_link(
               plug:
                 {PtcGateway.ConformanceProxy,
                  target: "http://" <> target_authority,
                  target_authority: target_authority,
                  proxy_authority: proxy_authority,
                  token: @token},
               ip: {127, 0, 0, 1},
               port: proxy_port,
               startup_log: false,
               http_2_options: [enabled: false]
             )

    on_exit(fn -> stop(proxy) end)
    executable = Path.expand("support/mcp_conformance/node_modules/.bin/conformance", __DIR__)

    for scenario <-
          ~w(server-stateless tools-list dns-rebinding-protection caching http-header-validation http-custom-header-server-validation) do
      {output, status} =
        System.cmd(
          executable,
          [
            "server",
            "--url",
            "http://#{proxy_authority}/mcp",
            "--scenario",
            scenario,
            "--spec-version",
            "2026-07-28",
            "--expected-failures",
            Path.expand("support/mcp_conformance/expected-failures.yml", __DIR__)
          ],
          stderr_to_stdout: true
        )

      assert status == 0, String.slice(output, -5_000, 5_000)
    end

    client_script = Path.expand("support/mcp_conformance/client_journey.mjs", __DIR__)

    {output, status} =
      System.cmd("node", [client_script, "http://#{target_authority}/mcp", @token],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert %{
             "discover" => discover,
             "listing" => listing,
             "read" => read,
             "write" => write,
             "contractFailure" => failure
           } = Jason.decode!(output)

    assert discover["supportedVersions"] == ["2026-07-28"]
    assert listing["tools"] == PtcGateway.Domain.metadata(owner).tools
    assert read["isError"] == false
    assert write["isError"] == false
    assert failure["isError"] == true
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

  defp audit_config(directory) do
    %{
      "directory" => directory,
      "max_file_bytes" => 1024,
      "max_retained_files" => 2
    }
  end

  defp audit_record(index) do
    %{
      "call_id" => "call-#{index}",
      "tool_name" => String.duplicate("tool", 40),
      "started_at" => "2026-09-16T00:00:00.000Z",
      "ended_at" => "2026-09-16T00:00:01.000Z",
      "outcome_code" => "success",
      "dispatch_state" => "true",
      "write_effects_may_have_occurred" => true,
      "disconnected" => false,
      "cleanup_status" => "complete"
    }
  end

  defp raw_mcp_status(config, extra_headers) do
    config |> raw_mcp_response(extra_headers) |> raw_status()
  end

  defp raw_mcp_response(config, extra_headers, opts \\ []) do
    port = config["listen"]["port"]
    body = Keyword.get(opts, :body, raw_mcp_body())
    headers = raw_mcp_headers(config, extra_headers, body, opts)

    request =
      [
        "POST #{Keyword.get(opts, :request_target, "/mcp")} HTTP/1.1\r\n",
        Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
        "\r\n",
        body
      ]

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, request)
    response = recv_to_close(socket, [])
    :gen_tcp.close(socket)
    response
  end

  defp recv_to_close(socket, chunks) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} -> recv_to_close(socket, [chunk | chunks])
      {:error, :closed} -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
      {:error, reason} -> flunk("raw HTTP response read failed: #{inspect(reason)}")
    end
  end

  defp raw_mcp_body do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/list",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    })
  end

  defp call_body(name, arguments) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        "name" => name,
        "arguments" => arguments
      }
    })
  end

  defp raw_mcp_headers(config, extra_headers, body, opts \\ []) do
    port = config["listen"]["port"]

    extra_headers =
      if Enum.any?(extra_headers, fn {name, _value} -> String.downcase(name) == "host" end),
        do: extra_headers,
        else: [{"Host", "127.0.0.1:#{port}"} | extra_headers]

    default_authorization =
      if Enum.any?(extra_headers, fn {name, _value} ->
           String.downcase(name) == "authorization"
         end),
         do: [],
         else: [{"Authorization", "Bearer #{@token}"}]

    default_method =
      if Keyword.get(opts, :method_header, true) and
           not Enum.any?(extra_headers, fn {name, _value} ->
             String.downcase(name) == "mcp-method"
           end),
         do: [{"Mcp-Method", "tools/list"}],
         else: []

    extra_headers ++
      default_authorization ++
      [
        {"Content-Type", "application/json"},
        {"Accept", "application/json, text/event-stream"},
        {"MCP-Protocol-Version", "2026-07-28"},
        {"Content-Length", Integer.to_string(byte_size(body))},
        {"Connection", "close"}
      ] ++ default_method
  end

  defp aggregate_padding_headers(config, target) do
    base_bytes = header_bytes(raw_mcp_headers(config, [], raw_mcp_body()))
    names = for index <- 1..4, do: "X-Pad-#{index}"
    value_bytes = target - base_bytes - Enum.sum(Enum.map(names, &byte_size/1))
    common = div(value_bytes, length(names))
    remainder = rem(value_bytes, length(names))

    names
    |> Enum.with_index()
    |> Enum.map(fn {name, index} ->
      {name, String.duplicate("x", common + if(index < remainder, do: 1, else: 0))}
    end)
  end

  defp header_bytes(headers),
    do: Enum.sum(Enum.map(headers, fn {name, value} -> byte_size(name) + byte_size(value) end))

  defp raw_status(response) do
    [_, status | _] = :binary.split(response, " ", [:global])
    String.to_integer(status)
  end

  defp raw_body(response) do
    case :binary.split(response, "\r\n\r\n") do
      [_headers, body] -> body
      [_headers] -> ""
    end
  end

  defp sized_json_object(size) do
    prefix = ~s({"padding":")
    suffix = ~s("})
    prefix <> String.duplicate("x", size - byte_size(prefix) - byte_size(suffix)) <> suffix
  end

  defp sized_meta(size) do
    base = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{},
      "padding" => ""
    }

    encoded_size = byte_size(Jason.encode!(base))
    Map.put(base, "padding", String.duplicate("x", size - encoded_size))
  end

  defp nest_json(0), do: 0
  defp nest_json(depth), do: [nest_json(depth - 1)]

  defp sized_schema(size) do
    base = %{"type" => "object", "description" => ""}
    {:ok, normalized, _compiled} = PtcRunner.Kernel.JSONSchema.compile(base)
    Map.put(base, "description", String.duplicate("x", size - deterministic_size(normalized)))
  end

  defp deterministic_size(value) do
    {:ok, encoded} = PtcRunner.Kernel.DeterministicJSON.encode(value)
    byte_size(encoded)
  end

  defp rewrite_schema_config(path, config, schema, tool_count) do
    directory = Path.dirname(path)
    File.write!(Path.join(directory, "schema.json"), Jason.encode!(schema))

    {:ok, template} =
      ServingTemplate.from_directory(
        Path.join(directory, "app.json"),
        Limits.installed_defaults()
      )

    digest = ServingTemplate.application_content_digest(template)
    base_tool = hd(config["tools"])

    tools =
      for index <- 1..tool_count do
        base_tool
        |> Map.put("name", "tool-#{String.pad_leading(Integer.to_string(index), 3, "0")}")
        |> Map.put("expected_application_content_digest", digest)
      end

    updated = Map.put(config, "tools", tools)
    File.write!(path, Jason.encode!(updated))
    updated
  end

  defp sized_static_config(path, config, target, :response) do
    tools = sized_static_tools(target, :response)
    schema = tools |> hd() |> Map.fetch!("inputSchema")
    updated = rewrite_schema_config(path, config, schema, length(tools))

    descriptions = Map.new(tools, &{&1["name"], &1["description"]})

    updated =
      update_in(
        updated,
        ["tools"],
        &Enum.map(&1, fn tool ->
          Map.replace!(tool, "description", Map.fetch!(descriptions, tool["name"]))
        end)
      )

    File.write!(path, Jason.encode!(updated))
    updated
  end

  defp sized_static_tools(target, kind) do
    schema = sized_schema(63_500)
    {:ok, normalized, _compiled} = PtcRunner.Kernel.JSONSchema.compile(schema)

    tools =
      for index <- 1..32 do
        %{
          "name" => "tool-#{String.pad_leading(Integer.to_string(index), 3, "0")}",
          "title" => "A",
          "description" => "A tool",
          "inputSchema" => normalized,
          "outputSchema" => normalized,
          "annotations" => %{"readOnlyHint" => true}
        }
      end

    sized_static_tools(tools, target, kind)
  end

  defp sized_static_tools(tools, target, kind) do
    size = static_fixture_size(tools, kind)

    if size > target, do: flunk("static fixture base exceeds target by #{size - target} bytes")

    {tools, remaining} =
      Enum.map_reduce(tools, target - size, fn tool, remaining ->
        added = min(remaining, 4096 - byte_size(tool["description"]))

        {Map.update!(tool, "description", &(&1 <> String.duplicate("x", added))),
         remaining - added}
      end)

    if remaining == 0,
      do: tools,
      else: flunk("static fixture lacks #{remaining} bytes of padding capacity")
  end

  defp static_fixture_size(tools, :catalog), do: deterministic_size(tools)

  defp static_fixture_size(tools, :response) do
    deterministic_size(%{
      "jsonrpc" => "2.0",
      "id" => String.duplicate(<<0>>, 256),
      "result" => %{
        "resultType" => "complete",
        "tools" => tools,
        "ttlMs" => 0,
        "cacheScope" => "private"
      }
    })
  end

  defp acquire_eventually(_admission, 0), do: :full

  defp acquire_eventually(admission, attempts) do
    case PtcGateway.RequestAdmission.acquire(admission) do
      :full -> acquire_eventually(admission, attempts - 1)
      result -> result
    end
  end

  defp await_run_release(_admission, 0), do: {:error, :timeout}

  defp await_run_release(admission, attempts) do
    case PtcRunner.Kernel.RunAdmission.snapshot(admission) do
      {:ok, %{in_use: 0}} ->
        :ok

      _ ->
        receive do
        after
          10 -> await_run_release(admission, attempts - 1)
        end
    end
  end
end
