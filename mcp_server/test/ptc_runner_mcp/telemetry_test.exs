defmodule PtcRunnerMcp.TelemetryTest do
  @moduledoc """
  Stream 5A — telemetry events per
  `Plans/http-transport-credentials.md` §11.

  Covers:

    * `[:upstream, :http, :request, :start | :stop]` — fires around
      every wire call (handshake + tools/call), with `name`,
      `jsonrpc_method`, `http_status` (success), `duration_ms`.
    * `[:upstream, :http, :request, :stop]` on transport-error too
      (e.g. wrong-port → connect_refused) — `http_status: nil`.
    * `[:upstream, :http, :session_lost]` — fires with hashed prior
      session id (NOT the raw id).
    * `[:credentials, :resolve, :start | :stop]` — fires per
      `materialize/2` call, metadata never carries the resolved value.
    * `[:credentials, :resolve, :error]` — short-atom reason, NOT a
      detail string.
    * `[:upstream, :http, :sse_array_compat]` — Phase 2C wiring still
      fires (verification test).

  All assertions audit telemetry payloads for resolved-binding-value
  / raw-session-id / auth-header leaks. The only "fingerprint of
  secret" pattern allowed is `prior_session_id_hash`.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Credentials
  alias PtcRunnerMcp.Credentials.Binding
  alias PtcRunnerMcp.Test.FakeHttpServer
  alias PtcRunnerMcp.Upstream.Http

  # ---- shared telemetry-handler ---------------------------------------------
  #
  # `:telemetry.attach/4` warns ("performance penalty") when the
  # handler is a local capture (anonymous fn / fn-without-module).
  # Define module functions that forward into the test pid via
  # config-supplied `:test_pid`. Each test attaches under a unique id
  # so parallel attachments don't collide.

  @doc false
  def forward(event, measurements, metadata, %{test_pid: pid}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  defp attach(events, label) do
    handler_id = {__MODULE__, label, System.unique_integer([:positive])}
    test_pid = self()

    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.forward/4, %{test_pid: test_pid})

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp unique_creds_name, do: :"creds_#{:erlang.unique_integer([:positive])}"

  defp start_creds(bindings) do
    name = unique_creds_name()
    _pid = start_supervised!({Credentials, [name: name, bindings: bindings]})
    name
  end

  defp literal_binding(name, value, opts) do
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

  defp file_binding(name, path, opts \\ []) do
    %Binding{
      name: name,
      source: :file,
      scheme_hint: Keyword.get(opts, :scheme_hint),
      spec: %{path: path}
    }
  end

  defp config(port, overrides \\ %{}) do
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

  defp boot_fake(scenario, opts \\ %{}) do
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

  # ───────── 1. [:upstream, :http, :request, :start | :stop] ─────────

  describe "upstream.http.request — start | stop on success" do
    test "fires around every POST with name + jsonrpc_method + http_status + duration_ms" do
      attach(
        [
          [:ptc_runner_mcp, :upstream, :http, :request, :start],
          [:ptc_runner_mcp, :upstream, :http, :request, :stop]
        ],
        :req_success
      )

      %{port: port} = boot_fake(:handshake_success, %{toolset: toolset()})

      name = unique_name("tel-req-ok")
      assert {:ok, _pid} = Http.start_link(name, config(port))
      on_exit(fn -> safe_stop(name) end)

      assert {:ok, _result} = Http.call(name, "echo", %{}, [])

      events = drain_request_events()

      # We must have observed start+stop pairs for at least:
      # initialize, notifications/initialized, tools/list, tools/call.
      methods = events |> Enum.map(& &1.method) |> Enum.uniq() |> Enum.sort()

      assert "initialize" in methods
      assert "notifications/initialized" in methods
      assert "tools/list" in methods
      assert "tools/call" in methods

      # Each :stop must carry name, jsonrpc_method, http_status,
      # duration_ms; each :start must carry name + jsonrpc_method only.
      for ev <- events, ev.phase == :start do
        assert ev.metadata.name == name
        assert is_binary(ev.metadata.jsonrpc_method)
        refute Map.has_key?(ev.metadata, :http_status)
      end

      for ev <- events, ev.phase == :stop do
        assert ev.metadata.name == name
        assert is_binary(ev.metadata.jsonrpc_method)
        # http_status: 200 for json-200 results, 202 for the
        # notifications/initialized step, an integer in any case.
        assert is_integer(ev.metadata.http_status)
        assert is_integer(ev.metadata.duration_ms)
        assert ev.metadata.duration_ms >= 0
      end

      # Every :start has a matching :stop (same method label).
      starts = events |> Enum.filter(&(&1.phase == :start)) |> Enum.map(& &1.method)
      stops = events |> Enum.filter(&(&1.phase == :stop)) |> Enum.map(& &1.method)
      assert Enum.sort(starts) == Enum.sort(stops)
    end
  end

  # ───────── 2. :request, :stop fires on transport error ─────────

  describe "upstream.http.request — stop on transport error" do
    test "wrong-port → :stop fires with http_status: nil and duration_ms" do
      attach(
        [
          [:ptc_runner_mcp, :upstream, :http, :request, :start],
          [:ptc_runner_mcp, :upstream, :http, :request, :stop]
        ],
        :req_transport_err
      )

      # 127.0.0.1:1 (or any unbound port) → connect_refused. Pick a
      # port from the high range that's almost certainly unbound, but
      # use 1 (privileged, won't bind) as a clean refusal source on
      # most local systems. On macOS/Linux dev boxes connect to :1 is
      # ECONNREFUSED.
      name = unique_name("tel-req-err")
      bad_port = 1

      assert {:error, {:upstream_unavailable, _detail}} =
               Http.start_link(
                 name,
                 config(bad_port, %{
                   handshake_timeout_ms: 500,
                   connect_timeout_ms: 500
                 })
               )

      events = drain_request_events()

      # Boot tries `initialize` first; it must have emitted both a
      # `:start` and a `:stop` before bailing out of `init/1`.
      stops = Enum.filter(events, &(&1.phase == :stop))
      assert stops != [], "expected at least one :request, :stop on transport error"

      # The first stop is for "initialize" (the only step that runs
      # before bail-out). Transport-error stops set http_status: nil
      # per §11.
      [first | _] = stops
      assert first.method == "initialize"
      assert first.metadata.http_status == nil
      assert is_integer(first.metadata.duration_ms)
      assert first.metadata.duration_ms >= 0
    end
  end

  # ───────── 3. [:upstream, :http, :session_lost] ─────────

  describe "upstream.http.session_lost" do
    test "fires with prior_session_id_hash (hashed, NOT raw)" do
      attach(
        [[:ptc_runner_mcp, :upstream, :http, :session_lost]],
        :session_lost
      )

      %{port: port} = boot_fake(:session_404_on_call)

      name = unique_name("tel-session-lost")
      assert {:ok, pid} = Http.start_link(name, config(port))

      # See `http_test.exs` — unlink to absorb the impl's abnormal
      # exit cleanly (test is not Connection).
      Process.unlink(pid)
      ref = Process.monitor(pid)

      assert {:error, :upstream_unavailable, "session_lost"} =
               Http.call(name, "any_tool", %{}, [])

      assert_receive {:DOWN, ^ref, :process, ^pid, :session_lost}, 2_000

      # Exactly one session_lost event for this caller.
      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :http, :session_lost], %{count: 1},
                      metadata},
                     1_000

      assert metadata.name == name
      assert is_binary(metadata.prior_session_id_hash)
      # 16 lowercase hex chars per `hash_session_id/1`.
      assert byte_size(metadata.prior_session_id_hash) == 16
      assert metadata.prior_session_id_hash =~ ~r/^[0-9a-f]{16}$/

      # The fixture uses `"test-session-<int>"` as the id; the hash
      # MUST NOT be the raw value. We don't know the exact id (the
      # fixture chooses it), but we do know the prefix — assert hash
      # does NOT carry it verbatim.
      refute String.contains?(metadata.prior_session_id_hash, "test-session-"),
             "prior_session_id_hash leaked the raw session id"
    end
  end

  # ───────── 4. [:credentials, :resolve, :start | :stop] ─────────

  describe "credentials.resolve — start | stop on success" do
    test "fires per materialize/2 call with binding + source + duration_ms" do
      attach(
        [
          [:ptc_runner_mcp, :credentials, :resolve, :start],
          [:ptc_runner_mcp, :credentials, :resolve, :stop],
          [:ptc_runner_mcp, :credentials, :resolve, :error]
        ],
        :creds_resolve_ok
      )

      creds =
        start_creds(%{
          "tok" => literal_binding("tok", "secret-bearer-12345", scheme_hint: :bearer)
        })

      assert {:ok, %{raw: "secret-bearer-12345", scheme_hint: :bearer}} =
               Credentials.materialize(creds, "tok")

      assert_receive {:telemetry, [:ptc_runner_mcp, :credentials, :resolve, :start], _meas,
                      start_md},
                     500

      assert start_md == %{binding: "tok"}

      assert_receive {:telemetry, [:ptc_runner_mcp, :credentials, :resolve, :stop], stop_meas,
                      stop_md},
                     500

      assert stop_md.binding == "tok"
      assert stop_md.source == :literal
      assert is_integer(stop_meas.duration_ms)
      assert stop_meas.duration_ms >= 0

      # No :error event must fire on success.
      refute_received {:telemetry, [:ptc_runner_mcp, :credentials, :resolve, :error], _, _}

      # Audit: the resolved value must NEVER appear in any telemetry
      # metadata. (Defense-in-depth — the implementation wires it on
      # purpose, but this assertion makes regressions visible.)
      audit_no_value_leak([start_md, stop_md], "secret-bearer-12345")
    end

    test "stop metadata source matches the binding source for :env and :file" do
      attach(
        [
          [:ptc_runner_mcp, :credentials, :resolve, :stop]
        ],
        :creds_source
      )

      env_var = "PTC_TEL_TEST_VAR_#{System.unique_integer([:positive])}"
      System.put_env(env_var, "env-secret-xyz")
      on_exit(fn -> System.delete_env(env_var) end)

      tmp_path = Path.join(System.tmp_dir!(), "ptc_tel_#{System.unique_integer([:positive])}")
      File.write!(tmp_path, "file-secret-abc\n")
      on_exit(fn -> File.rm(tmp_path) end)

      creds =
        start_creds(%{
          "evar" => env_binding("evar", env_var),
          "fvar" => file_binding("fvar", tmp_path)
        })

      assert {:ok, _} = Credentials.materialize(creds, "evar")

      assert_receive {:telemetry, [:ptc_runner_mcp, :credentials, :resolve, :stop], _,
                      %{binding: "evar", source: :env}},
                     500

      assert {:ok, _} = Credentials.materialize(creds, "fvar")

      assert_receive {:telemetry, [:ptc_runner_mcp, :credentials, :resolve, :stop], _,
                      %{binding: "fvar", source: :file}},
                     500
    end
  end

  # ───────── 5. [:credentials, :resolve, :error] ─────────

  describe "credentials.resolve — error" do
    test "unset env var → :env_missing (short atom, NOT a path / detail string)" do
      attach(
        [[:ptc_runner_mcp, :credentials, :resolve, :error]],
        :creds_err_env
      )

      env_var = "PTC_TEL_NOT_SET_#{System.unique_integer([:positive])}"
      System.delete_env(env_var)

      creds = start_creds(%{"missing" => env_binding("missing", env_var)})

      assert {:error, :resolution_failed, _detail} =
               Credentials.materialize(creds, "missing")

      assert_receive {:telemetry, [:ptc_runner_mcp, :credentials, :resolve, :error], _, metadata},
                     500

      assert metadata.binding == "missing"
      assert metadata.source == :env
      assert metadata.reason == :env_missing
      # CRITICAL: reason is a short atom, NOT a detail string. The
      # detail string ("env var '...' is not set") might in theory
      # echo a path-like fragment if the var were named after a
      # filesystem location.
      assert is_atom(metadata.reason)
      refute is_binary(metadata.reason)
      # Audit: the env-var name itself must not be the only signal —
      # binding name is fine, source + reason atoms are fine.
      refute Map.has_key?(metadata, :detail)
    end

    test "missing file → :file_not_found (NOT the path)" do
      attach(
        [[:ptc_runner_mcp, :credentials, :resolve, :error]],
        :creds_err_file
      )

      missing_path =
        Path.join(
          System.tmp_dir!(),
          "ptc_tel_does_not_exist_#{System.unique_integer([:positive])}"
        )

      refute File.exists?(missing_path)

      creds = start_creds(%{"f" => file_binding("f", missing_path)})

      assert {:error, :resolution_failed, _detail} =
               Credentials.materialize(creds, "f")

      assert_receive {:telemetry, [:ptc_runner_mcp, :credentials, :resolve, :error], _, metadata},
                     500

      assert metadata.binding == "f"
      assert metadata.source == :file
      assert metadata.reason == :file_not_found

      # Audit: path MUST NOT be in the metadata (the detail string
      # contains it, but the metadata does not).
      audit_no_value_leak([metadata], missing_path)
    end

    test "unknown binding → :unknown_binding" do
      attach(
        [[:ptc_runner_mcp, :credentials, :resolve, :error]],
        :creds_err_unknown
      )

      creds = start_creds(%{})

      assert {:error, :unknown_binding, _detail} =
               Credentials.materialize(creds, "nonexistent")

      assert_receive {:telemetry, [:ptc_runner_mcp, :credentials, :resolve, :error], _,
                      %{binding: "nonexistent", source: :unknown, reason: :unknown_binding}},
                     500
    end
  end

  # ───────── 6. [:upstream, :http, :sse_array_compat] verification ─────────

  describe "upstream.http.sse_array_compat (Phase 2C — still firing)" do
    test ":sse_response_array_form path emits the event" do
      attach(
        [[:ptc_runner_mcp, :upstream, :http, :sse_array_compat]],
        :sse_array
      )

      %{port: port} = boot_fake(:sse_response_array_form)

      name = unique_name("tel-sse-array")
      assert {:ok, _pid} = Http.start_link(name, config(port))
      on_exit(fn -> safe_stop(name) end)

      assert {:ok, %{"content" => [%{"type" => "text", "text" => "ok"}]}} =
               Http.call(name, "echo", %{}, [])

      assert_receive {:telemetry, [:ptc_runner_mcp, :upstream, :http, :sse_array_compat],
                      %{count: 1}, _metadata},
                     1_000
    end
  end

  # ---- helpers -------------------------------------------------------------

  # Drain all `:upstream, :http, :request, :*` events from the mailbox
  # into a flat list of `%{phase, method, measurements, metadata}`.
  # Drains until the mailbox quiesces for ~50ms.
  defp drain_request_events(acc \\ []) do
    receive do
      {:telemetry, [:ptc_runner_mcp, :upstream, :http, :request, phase], meas, md} ->
        ev = %{
          phase: phase,
          method: md.jsonrpc_method,
          measurements: meas,
          metadata: md
        }

        drain_request_events([ev | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  # Walk a list of metadata maps and assert the secret value is NOT
  # present in any binary leaf. Defense-in-depth: regressions that
  # accidentally splice the resolved value into telemetry will trip
  # this assertion.
  defp audit_no_value_leak(maps, secret) when is_binary(secret) do
    for m <- maps, {_k, v} <- m, is_binary(v) do
      refute String.contains?(v, secret),
             "telemetry metadata leaked secret #{inspect(secret)} via value #{inspect(v)}"
    end
  end
end
