defmodule PtcRunnerMcp.Upstream.HttpAuthTest do
  @moduledoc """
  Stream 3C integration tests for `PtcRunnerMcp.Upstream.Http`'s
  per-request auth integration against the
  `PtcRunnerMcp.Test.FakeHttpServer` fixture.

  Covers:

    * Per-request materialize → apply_emitter → header-splice flow
      (`bearer`, `basic`, `custom_header`, multi-emitter).
    * Auth headers present on EVERY POST including `initialize`
      (§6.1.1).
    * 401 on `tools/call` → `:auth_failed` abnormal exit (§4.3.1).
    * Cold-start re-materialization on rotation (§7.4 — no value cache).
    * Boot-time `:resolution_failed` rendering (§8.3).
    * Defense-in-depth `:scheme_mismatch` covered by 3A's tests; here
      we only confirm the request path's error wrapping.
    * Smoke-only redaction end-to-end probe (full property test is
      stream 3D's job).

  Spec: `Plans/http-transport-credentials.md` Phase 3, §5.3.1, §7.3,
  §8.3.

  `:async: false` because each test stands up a Bandit listener and a
  Credentials GenServer instance.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PtcRunnerMcp.Credentials
  alias PtcRunnerMcp.Credentials.Binding
  alias PtcRunnerMcp.Test.FakeHttpServer
  alias PtcRunnerMcp.Upstream.Http

  # ---- helpers --------------------------------------------------------------

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp unique_creds_name do
    :"creds_#{:erlang.unique_integer([:positive])}"
  end

  defp start_creds(bindings) do
    name = unique_creds_name()
    _pid = start_supervised!({Credentials, [name: name, bindings: bindings]})
    name
  end

  defp literal_binding(name, value, opts \\ []) do
    %Binding{
      name: name,
      source: :literal,
      scheme_hint: Keyword.get(opts, :scheme_hint),
      spec: %{value: value}
    }
  end

  defp env_binding(name, var, opts \\ []) do
    %Binding{
      name: name,
      source: :env,
      scheme_hint: Keyword.get(opts, :scheme_hint),
      spec: %{var: var}
    }
  end

  defp config(port, overrides) do
    base = %{
      url: "http://127.0.0.1:#{port}/mcp",
      handshake_timeout_ms: 2_000,
      request_timeout_ms: 2_000,
      connect_timeout_ms: 1_000,
      max_response_bytes: 256 * 1024,
      pool_size: 2
    }

    Map.merge(base, overrides)
  end

  defp boot_fake(scenario, opts) do
    server =
      start_supervised!(
        {FakeHttpServer, scenario: scenario, opts: opts},
        id: {FakeHttpServer, System.unique_integer([:positive])}
      )

    %{server: server, port: FakeHttpServer.port(server)}
  end

  defp safe_stop(name) do
    Http.stop(name)
  catch
    :exit, _ -> :ok
  end

  defp toolset do
    [
      %{
        "name" => "echo",
        "description" => "echoes",
        "inputSchema" => %{"type" => "object"}
      }
    ]
  end

  # ───────── 1. Bearer happy path ─────────

  describe "bearer auth" do
    test "literal binding produces Authorization: Bearer <token> on every request" do
      creds = start_creds(%{"tok" => literal_binding("tok", "actual-token")})
      %{server: server, port: port} = boot_fake(:handshake_success, %{toolset: toolset()})

      auth_cfg = %{
        auth: [%{scheme: :bearer, binding: "tok", header: nil}],
        credentials: creds
      }

      name = unique_name("http-bearer")
      assert {:ok, _pid} = Http.start_link(name, config(port, auth_cfg))
      on_exit(fn -> safe_stop(name) end)

      assert {:ok, _result} = Http.call(name, "echo", %{}, [])

      requests = FakeHttpServer.received_requests(server)

      # All requests (initialize → notifications/initialized →
      # tools/list → tools/call) MUST carry the Authorization header
      # — auth is required from the very first POST per §6.1.1.
      auth_values =
        requests
        |> Enum.map(fn req ->
          {req_method(req),
           Enum.find_value(req.headers, fn
             {"authorization", v} -> v
             _ -> nil
           end)}
        end)

      # Sanity: we observed 4 distinct request methods (handshake
      # trio + tools/call).
      methods = Enum.map(auth_values, &elem(&1, 0))

      assert "initialize" in methods
      assert "notifications/initialized" in methods
      assert "tools/list" in methods
      assert "tools/call" in methods

      # Every recorded request carries the bearer header.
      for {method, value} <- auth_values do
        assert value == "Bearer actual-token",
               "request #{inspect(method)} missing/wrong Authorization header"
      end
    end
  end

  # ───────── 2. Custom-header happy path ─────────

  describe "custom_header auth" do
    test "produces lowercased custom header on every request" do
      creds = start_creds(%{"tok" => literal_binding("tok", "key-xyz")})
      %{server: server, port: port} = boot_fake(:handshake_success, %{toolset: toolset()})

      auth_cfg = %{
        auth: [%{scheme: :custom_header, binding: "tok", header: "X-Api-Key"}],
        credentials: creds
      }

      name = unique_name("http-custom")
      assert {:ok, _pid} = Http.start_link(name, config(port, auth_cfg))
      on_exit(fn -> safe_stop(name) end)

      assert {:ok, _result} = Http.call(name, "echo", %{}, [])

      [first | _rest] = FakeHttpServer.received_requests(server)

      # Lowercased header name on the wire; verbatim binding value.
      assert {"x-api-key", "key-xyz"} in first.headers
    end
  end

  # ───────── 3. Basic auth (user:pass form) ─────────

  describe "basic auth" do
    test "user:pass colon-form encodes to Authorization: Basic <b64>" do
      creds = start_creds(%{"tok" => literal_binding("tok", "alice:secret")})
      %{server: server, port: port} = boot_fake(:handshake_success, %{toolset: toolset()})

      auth_cfg = %{
        auth: [%{scheme: :basic, binding: "tok", header: nil}],
        credentials: creds
      }

      name = unique_name("http-basic-colon")
      assert {:ok, _pid} = Http.start_link(name, config(port, auth_cfg))
      on_exit(fn -> safe_stop(name) end)

      assert {:ok, _} = Http.call(name, "echo", %{}, [])

      [first | _] = FakeHttpServer.received_requests(server)
      expected = "Basic " <> Base.encode64("alice:secret")
      assert {"authorization", ^expected} = List.keyfind(first.headers, "authorization", 0)
    end

    # ───────── 4. Basic auth (JSON form) ─────────

    test "JSON-shaped raw {user,pass} encodes to same Authorization output" do
      creds =
        start_creds(%{
          "tok" => literal_binding("tok", ~s({"user":"alice","pass":"secret"}))
        })

      %{server: server, port: port} = boot_fake(:handshake_success, %{toolset: toolset()})

      auth_cfg = %{
        auth: [%{scheme: :basic, binding: "tok", header: nil}],
        credentials: creds
      }

      name = unique_name("http-basic-json")
      assert {:ok, _pid} = Http.start_link(name, config(port, auth_cfg))
      on_exit(fn -> safe_stop(name) end)

      assert {:ok, _} = Http.call(name, "echo", %{}, [])

      [first | _] = FakeHttpServer.received_requests(server)
      expected = "Basic " <> Base.encode64("alice:secret")
      assert {"authorization", ^expected} = List.keyfind(first.headers, "authorization", 0)
    end
  end

  # ───────── 5. Multi-emitter ordering ─────────

  describe "multi-emitter" do
    test "bearer + custom_header — both headers present in declared order" do
      creds =
        start_creds(%{
          "tok1" => literal_binding("tok1", "abc"),
          "tok2" => literal_binding("tok2", "xyz")
        })

      %{server: server, port: port} = boot_fake(:handshake_success, %{toolset: toolset()})

      auth_cfg = %{
        auth: [
          %{scheme: :bearer, binding: "tok1", header: nil},
          %{scheme: :custom_header, binding: "tok2", header: "X-Extra"}
        ],
        credentials: creds
      }

      name = unique_name("http-multi")
      assert {:ok, _pid} = Http.start_link(name, config(port, auth_cfg))
      on_exit(fn -> safe_stop(name) end)

      assert {:ok, _} = Http.call(name, "echo", %{}, [])

      [first | _] = FakeHttpServer.received_requests(server)

      # Both headers are present.
      assert {"authorization", "Bearer abc"} =
               List.keyfind(first.headers, "authorization", 0)

      assert {"x-extra", "xyz"} = List.keyfind(first.headers, "x-extra", 0)

      # Authorization comes BEFORE x-extra in the wire order — the
      # impl appends auth headers as `base ++ static ++ auth` and
      # the auth list itself is in declared emitter order.
      auth_idx = Enum.find_index(first.headers, &match?({"authorization", _}, &1))
      extra_idx = Enum.find_index(first.headers, &match?({"x-extra", _}, &1))
      assert auth_idx < extra_idx
    end
  end

  # ───────── 6. 401 → :auth_failed exit ─────────

  describe "post-handshake 401 → :auth_failed abnormal exit" do
    test ":tools_call_401 triggers :auth_failed reason on the impl GenServer" do
      creds = start_creds(%{"tok" => literal_binding("tok", "ok-token")})
      %{port: port} = boot_fake(:tools_call_401, %{toolset: toolset()})

      auth_cfg = %{
        auth: [%{scheme: :bearer, binding: "tok", header: nil}],
        credentials: creds
      }

      name = unique_name("http-401")
      assert {:ok, pid} = Http.start_link(name, config(port, auth_cfg))

      # Same defense as the session-loss test in http_test.exs:
      # `Http.start_link/2` linked us to the impl, and the impl is
      # about to abnormal-exit. Unlink before triggering or the
      # signal will tear the test process down.
      Process.unlink(pid)
      ref = Process.monitor(pid)

      assert {:error, :upstream_unavailable, "auth_failed"} =
               Http.call(name, "echo", %{}, [])

      # Connection's existing `:DOWN` path arms backoff when reason is
      # :auth_failed (§4.3.1). Here we just verify the abnormal exit
      # itself.
      assert_receive {:DOWN, ^ref, :process, ^pid, :auth_failed}, 2_000
    end
  end

  # ───────── 7. Cold-start re-materialization on rotation (§7.4) ─────────

  describe "no value cache (§7.4)" do
    test "env binding rotation is picked up on next cold-start materialize" do
      env_var = "PTC_TEST_AUTH_ROTATION_#{System.unique_integer([:positive])}"
      System.put_env(env_var, "value-1")
      on_exit(fn -> System.delete_env(env_var) end)

      creds = start_creds(%{"tok" => env_binding("tok", env_var)})
      %{server: server, port: port} = boot_fake(:handshake_success, %{toolset: toolset()})

      auth_cfg = %{
        auth: [%{scheme: :bearer, binding: "tok", header: nil}],
        credentials: creds
      }

      name = unique_name("http-rotation")
      assert {:ok, _pid} = Http.start_link(name, config(port, auth_cfg))
      on_exit(fn -> safe_stop(name) end)

      assert {:ok, _} = Http.call(name, "echo", %{}, [])

      first_call =
        FakeHttpServer.received_requests(server)
        |> Enum.find(fn r -> match?(%{"method" => "tools/call"}, r.decoded) end)

      assert {"authorization", "Bearer value-1"} =
               List.keyfind(first_call.headers, "authorization", 0)

      # Rotate the env var. v1 has no value cache, so the next
      # request must materialize the new value (§7.4).
      System.put_env(env_var, "value-2")

      assert {:ok, _} = Http.call(name, "echo", %{}, [])

      tools_calls =
        FakeHttpServer.received_requests(server)
        |> Enum.filter(fn r -> match?(%{"method" => "tools/call"}, r.decoded) end)

      assert length(tools_calls) == 2

      [_first, second] = tools_calls

      assert {"authorization", "Bearer value-2"} =
               List.keyfind(second.headers, "authorization", 0)
    end
  end

  # ───────── 8. Boot-time :resolution_failed rendering (§8.3) ─────────

  describe "boot-time resolution failure" do
    test "env binding pointing at unset var fails init with §8.3 detail" do
      missing_var = "PTC_TEST_NEVER_SET_#{System.unique_integer([:positive])}"
      System.delete_env(missing_var)

      creds = start_creds(%{"tok" => env_binding("tok", missing_var)})
      %{port: port} = boot_fake(:handshake_success, %{toolset: toolset()})

      auth_cfg = %{
        auth: [%{scheme: :bearer, binding: "tok", header: nil}],
        credentials: creds
      }

      name = unique_name("http-boot-fail")

      # `start_link/2` returns `{:error, {:upstream_unavailable, detail}}`
      # for handshake-time init failures (codex-fix wrap that traps
      # exits during start). §8.3: detail starts with
      # "resolution_failed: <binding-name>".
      assert {:error, {:upstream_unavailable, detail}} =
               Http.start_link(name, config(port, auth_cfg))

      assert String.starts_with?(detail, "resolution_failed: tok"),
             "expected '#{detail}' to start with 'resolution_failed: tok'"
    end
  end

  # ───────── 9. scheme_mismatch defense-in-depth (request path) ─────────

  describe "scheme_mismatch at request time" do
    test "binding scheme_hint :bearer + emitter scheme :custom_header surfaces auth_failed" do
      # Defense-in-depth: 3A's tests already cover the pure
      # apply_emitter/2 error. Here we exercise the request-path
      # wrapping — the operator-bypass path that 3A's signature
      # promise exists to catch.
      creds =
        start_creds(%{
          "tok" => literal_binding("tok", "abc", scheme_hint: :bearer)
        })

      %{port: port} = boot_fake(:handshake_success, %{toolset: toolset()})

      auth_cfg = %{
        # NOTE: emitter scheme :custom_header but binding scheme_hint
        # is :bearer — config validator would normally catch this,
        # but the impl must still error cleanly if it fires.
        auth: [%{scheme: :custom_header, binding: "tok", header: "X-Foo"}],
        credentials: creds
      }

      name = unique_name("http-scheme-mismatch")

      # The MISMATCH fires on the very first auth resolution call,
      # which happens inside `init/1`'s handshake step 1. So
      # `start_link/2` returns `{:error, {:upstream_unavailable, _}}`
      # — same path as boot-time resolution failure.
      assert {:error, {:upstream_unavailable, detail}} =
               Http.start_link(name, config(port, auth_cfg))

      # Boot-time path passes the bare `apply_emitter/2` error detail
      # through. We just want to confirm it didn't crash and the
      # detail mentions the mismatch.
      assert detail =~ "scheme_mismatch" or detail =~ "incompatible",
             "expected scheme-mismatch signal in: #{inspect(detail)}"
    end
  end

  # ───────── 10. Redaction smoke test (full version is stream 3D's) ─────────

  describe "secret redaction smoke test (stream 3D writes the property test)" do
    test "secret bytes don't appear in logs or impl GenServer state" do
      secret = "my-test-secret-32-bytes-randomzz"
      creds = start_creds(%{"tok" => literal_binding("tok", secret)})
      %{port: port} = boot_fake(:handshake_success, %{toolset: toolset()})

      auth_cfg = %{
        auth: [%{scheme: :bearer, binding: "tok", header: nil}],
        credentials: creds
      }

      name = unique_name("http-redact-smoke")

      # Capture stderr (Log emissions go through PtcRunnerMcp.Log
      # which writes to standard_error) for the full lifecycle:
      # start, one call, stop.
      stderr_output =
        capture_log(fn ->
          assert {:ok, pid} = Http.start_link(name, config(port, auth_cfg))
          assert {:ok, _} = Http.call(name, "echo", %{}, [])

          # Defense-in-depth: inspect impl GenServer state directly.
          # The state must NOT carry the secret anywhere reachable by
          # `inspect/2` (the auth headers are derived per request and
          # dropped; only the EMITTER list is on state, which carries
          # only the binding NAME).
          state = :sys.get_state(pid)
          state_str = inspect(state, limit: :infinity, printable_limit: :infinity)
          refute state_str =~ secret, "impl GenServer state leaked the secret"

          safe_stop(name)
        end)

      refute stderr_output =~ secret,
             "captured log output leaked the secret bytes"
    end
  end

  # ───────── helpers ─────────

  defp req_method(req) do
    case req.decoded do
      %{"method" => m} when is_binary(m) -> m
      _ -> nil
    end
  end
end
