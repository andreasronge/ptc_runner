defmodule PtcRunnerMcp.Http.RouterAdminTest do
  use PtcRunnerMcp.Http.RouterCase

  alias PtcRunner.PreludeStore
  alias PtcRunnerMcp.Http.AuthRateLimiter
  alias PtcRunnerMcp.Http.Config, as: HttpConfig
  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig

  @admin_token String.duplicate("z", 32)

  test "admin routes are not available when the admin token is unset" do
    conn =
      conn(:get, "/admin/prelude-store/snapshot")
      |> call()

    assert conn.status == 404
    assert conn.resp_body == "not found"
  end

  test "admin routes require the admin token and reject the MCP token" do
    configure_admin!()

    missing =
      conn(:get, "/admin/prelude-store/snapshot")
      |> call()

    assert missing.status == 401

    wrong =
      conn(:get, "/admin/prelude-store/snapshot")
      |> auth()
      |> call()

    assert wrong.status == 401
  end

  test "admin routes enforce loopback host and origin guards" do
    configure_admin!()

    bad_host =
      conn(:get, "/admin/prelude-store/snapshot")
      |> with_host("evil.test")
      |> admin_auth()
      |> call()

    assert bad_host.status == 403

    bad_origin =
      conn(:get, "/admin/prelude-store/snapshot")
      |> put_req_header("origin", "http://evil.test")
      |> admin_auth()
      |> call()

    assert bad_origin.status == 403
  end

  test "admin auth failures are rate limited with only an admin token configured" do
    {:ok, cfg} =
      HttpConfig.resolve(%{
        http: true,
        http_admin_token: @admin_token,
        http_auth_rate_limit: true,
        http_auth_rate_limit_max_failures: 1,
        http_auth_rate_limit_window_ms: 60_000,
        http_auth_rate_limit_block_ms: 60_000
      })

    Application.put_env(:ptc_runner_mcp, :http_config, cfg)
    start_supervised!({AuthRateLimiter, [config: cfg]})

    first =
      conn(:get, "/admin/prelude-store/snapshot")
      |> put_req_header("authorization", "Bearer wrong")
      |> call()

    assert first.status == 401

    blocked =
      conn(:get, "/admin/prelude-store/snapshot")
      |> put_req_header("authorization", "Bearer wrong")
      |> call()

    assert blocked.status == 429
    assert get_resp_header(blocked, "retry-after") != []
    assert get_resp_header(blocked, "www-authenticate") == []
  end

  test "snapshot stamps lifecycle, build, and fingerprint fields" do
    store = configure_admin_with_store!()

    conn =
      conn(:get, "/admin/prelude-store/snapshot")
      |> admin_auth()
      |> call()

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert body["status"] == "ok"
    assert body["schema_version"] == 1
    assert is_binary(body["boot_id"])
    assert is_binary(body["commit"])
    assert is_boolean(body["git_dirty"])
    assert is_binary(body["created_at"])
    assert body["store_fingerprint"] == PreludeStore.store_fingerprint(store)
    assert body["snapshot"]["schema_version"] == 1
  end

  test "export returns a seed-compatible bundle from the live store" do
    store = configure_admin_with_store!()

    conn =
      conn(:get, "/admin/prelude-store/export")
      |> admin_auth()
      |> call()

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert body["status"] == "ok"
    assert body["store_fingerprint"] == PreludeStore.store_fingerprint(store)
    assert body["manifest"]["store_fingerprint"] == body["store_fingerprint"]

    files = Map.new(body["files"], &{&1["path"], &1["source"]})
    assert files["base.clj"] =~ "(ns base)"
    assert files["audit.clj"] =~ "(ns audit)"
    assert files["audit.deps"] == "base\n"
    refute Map.has_key?(files, "base.deps")
  end

  test "admin routes return structured JSON when host metadata cannot be encoded" do
    {:ok, store} = PreludeStore.new()

    assert {:ok, _candidate} =
             PreludeStore.write(store, "meta", "(ns meta)\n(defn value [] 1)\n", %{
               "reason" => self()
             })

    configure_admin!()
    SessionsConfig.set(SessionsConfig.get() |> Map.put(:prelude_store, store))

    for path <- ["/admin/prelude-store/snapshot", "/admin/prelude-store/export"] do
      conn =
        conn(:get, path)
        |> admin_auth()
        |> call()

      assert conn.status == 500
      body = Jason.decode!(conn.resp_body)
      assert body["reason"] == "admin_response_encode_failed"
    end
  end

  test "admin route reports an unavailable store without exposing auth details" do
    configure_admin!()
    SessionsConfig.set(SessionsConfig.get() |> Map.put(:prelude_store, nil))

    conn =
      conn(:get, "/admin/prelude-store/export")
      |> admin_auth()
      |> call()

    assert conn.status == 503
    body = Jason.decode!(conn.resp_body)
    assert body["reason"] == "prelude_store_unavailable"
    refute body["message"] =~ @admin_token
  end

  test "export fails closed when the flattened seed bundle would lose dependency pins" do
    store = seed_store_with_non_current_dep_pin!()
    configure_admin!()
    SessionsConfig.set(SessionsConfig.get() |> Map.put(:prelude_store, store))

    conn =
      conn(:get, "/admin/prelude-store/export")
      |> admin_auth()
      |> call()

    assert conn.status == 409
    body = Jason.decode!(conn.resp_body)
    assert body["reason"] == "non_current_dependency_pin"
    assert body["message"] =~ "use snapshot/restore"
  end

  defp configure_admin_with_store! do
    store = seed_store!()
    configure_admin!()
    SessionsConfig.set(SessionsConfig.get() |> Map.put(:prelude_store, store))
    store
  end

  defp configure_admin! do
    {:ok, cfg} =
      HttpConfig.resolve(%{
        http: true,
        http_auth_token: @token,
        http_admin_token: @admin_token
      })

    Application.put_env(:ptc_runner_mcp, :http_config, cfg)
  end

  defp admin_auth(conn), do: put_req_header(conn, "authorization", "Bearer " <> @admin_token)

  defp seed_store! do
    {:ok, store} = PreludeStore.new()

    base = "(ns base)\n(defn helper [x] x)\n"
    audit = "(ns audit)\n(defn check [x] (base/helper x))\n"

    {:ok, base_version} = PreludeStore.write(store, "base", base)

    {:ok, _audit_version} =
      PreludeStore.write(store, "audit", audit, %{
        "requires_preludes" => ["base@#{base_version.version}"]
      })

    store
  end

  defp seed_store_with_non_current_dep_pin! do
    {:ok, store} = PreludeStore.new()

    base_v1 = "(ns base)\n(defn helper [x] x)\n"
    audit = "(ns audit)\n(defn check [x] (base/helper x))\n"
    base_v2 = "(ns base)\n(defn helper2 [x] x)\n"

    {:ok, base} = PreludeStore.write(store, "base", base_v1)

    {:ok, _audit_version} =
      PreludeStore.write(store, "audit", audit, %{
        "requires_preludes" => ["base@#{base.version}"]
      })

    {:ok, _base_v2} =
      PreludeStore.write(store, "base", base_v2, %{
        "parent_checksum" => base.checksum,
        "parent_version" => base.version
      })

    store
  end
end
