defmodule PtcRunnerMcp.Upstream.HttpPhase2gTest do
  @moduledoc """
  Phase 2G integration coverage gaps for `PtcRunnerMcp.Upstream.Http`.

  Per `Plans/http-transport-credentials.md` §13.2 / Phase 2 deliverables.
  Phase 2D (`http_test.exs`) covered the wire-level handshake / session /
  classification / headers / `stop/1` paths; Phase 2C
  (`http/sse_decoder_test.exs`) unit-tested the SSE decoder; Phase 2E
  (`application_credentials_test.exs`) covered the config loader. This
  file fills the remaining integration gaps:

    * SSE end-to-end through `Upstream.Http.call/4` (single-message and
      array-form, the latter asserting telemetry).
    * Cumulative `:response_too_large` against an SSE stream.
    * Pool exhaustion → request-timeout when the upstream serves
      requests sequentially under `pool_size: 1`.
    * Eager-start integration: an HTTP upstream that 503s at boot is
      non-fatal (§4.3) and renders as "(unavailable at startup)".
    * Connection-lifecycle through `Registry → Connection → Http.call/4`
      end-to-end.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Test.FakeHttpServer
  alias PtcRunnerMcp.Upstream.Catalog
  alias PtcRunnerMcp.Upstream.Connection
  alias PtcRunnerMcp.Upstream.Http
  alias PtcRunnerMcp.Upstream.Registry, as: UpstreamRegistry
  alias PtcRunnerMcp.Upstream.Supervisor, as: UpstreamSupervisor

  @doc false
  # Module-level telemetry handler — `:telemetry.attach/4` warns if the
  # handler is a local capture (anonymous fn / fn-without-module),
  # citing the performance penalty of dispatching to a capture.
  def forward_telemetry(event, measurements, metadata, %{test_pid: pid}) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
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

  # ───────── A. SSE end-to-end through Upstream.Http ─────────

  describe "SSE responses through Upstream.Http.call/4" do
    test ":sse_response_single_message — Transport delegates to SseDecoder, surfaces result" do
      %{port: port} = boot_fake(:sse_response_single_message)

      name = unique_name("http-sse-single")
      assert {:ok, _pid} = Http.start_link(name, config(port))
      on_exit(fn -> safe_stop(name) end)

      # Single SSE event whose `data:` line carries one JSON-RPC
      # response message. The decoder matches on the in-flight id and
      # surfaces `{:ok, result}` to the caller.
      assert {:ok, %{"content" => [%{"type" => "text", "text" => "ok"}]}} =
               Http.call(name, "echo", %{}, [])
    end

    test ":sse_response_array_form — array dispatch surfaces result + emits telemetry" do
      handler_id = {__MODULE__, :sse_array_compat, System.unique_integer([:positive])}
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:ptc_runner_mcp, :upstream, :http, :sse_array_compat],
          &__MODULE__.forward_telemetry/4,
          %{test_pid: test_pid}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      %{port: port} = boot_fake(:sse_response_array_form)

      name = unique_name("http-sse-array")
      assert {:ok, _pid} = Http.start_link(name, config(port))
      on_exit(fn -> safe_stop(name) end)

      # Array-form: one SSE event whose `data:` line is a JSON array
      # `[notification, response]`. The notification has no id and is
      # dropped; the response matches the in-flight id and is surfaced.
      assert {:ok, %{"content" => [%{"type" => "text", "text" => "ok"}]}} =
               Http.call(name, "echo", %{}, [])

      # Exactly one telemetry event for the array-compat path.
      assert_receive {:telemetry_event, [:ptc_runner_mcp, :upstream, :http, :sse_array_compat],
                      %{count: 1}, _metadata},
                     1_000

      refute_received {:telemetry_event, [:ptc_runner_mcp, :upstream, :http, :sse_array_compat],
                       _, _}
    end
  end

  # ───────── B. Cumulative :response_too_large against an SSE stream ─────────

  describe "SSE cumulative cap (§6.4.1)" do
    test ":large_sse_stream — cumulative byte-cap trips :response_too_large" do
      %{port: port} = boot_fake(:large_sse_stream)

      # 8 KiB cap — fixture sends 2 KiB chunks, so a few chunks in we
      # exceed the cap and the decoder must abort. Bump the request
      # timeout high enough that the cap trips well before the timeout.
      name = unique_name("http-sse-large")

      assert {:ok, _pid} =
               Http.start_link(
                 name,
                 config(port, %{
                   max_response_bytes: 8_192,
                   request_timeout_ms: 5_000
                 })
               )

      on_exit(fn -> safe_stop(name) end)

      assert {:error, :response_too_large, detail} = Http.call(name, "echo", %{}, [])
      # Detail must reference the cap so operators can correlate.
      assert detail =~ "8192" or detail =~ "cap"
    end
  end

  # ───────── C. Pool exhaustion → queue + timeout ─────────
  #
  # Spec ambiguity (flagged in the 2G hand-off): the brief framed
  # this as "pool exhaustion → second concurrent caller queues at the
  # Finch pool and times out". In the current `Upstream.Http` impl
  # `tools/call` is dispatched via `GenServer.call(pid, {:tools_call,
  # ...})`, so concurrent callers serialize at the impl GenServer's
  # mailbox BEFORE ever touching Finch. `pool_size: 1` is therefore
  # not the load-bearing knob — `request_timeout_ms` is. The
  # observable property the spec is reaching for is "a slow upstream
  # produces `:timeout` for concurrent callers", which we validate
  # below: both concurrent callers get `:timeout` (the second was
  # queued at the impl's mailbox; once dequeued, its own 100 ms
  # `request_timeout_ms` trips against the 500 ms fixture delay).
  describe "concurrent callers against a slow upstream" do
    test "concurrent tools/call requests both surface :timeout against a 500 ms-delayed fixture" do
      %{port: port} = boot_fake(:tools_call_slow, %{delay_ms: 500})

      name = unique_name("http-slow-concurrent")

      assert {:ok, _pid} =
               Http.start_link(
                 name,
                 config(port, %{
                   pool_size: 1,
                   # Handshake must complete cleanly — give it plenty
                   # of room (the slow scenario only delays
                   # `tools/call`, not handshake steps).
                   handshake_timeout_ms: 5_000,
                   request_timeout_ms: 100
                 })
               )

      on_exit(fn -> safe_stop(name) end)

      task1 = Task.async(fn -> Http.call(name, "echo", %{}, []) end)
      # Tiny stagger so the first request reaches the impl GenServer
      # first (the second queues in the mailbox behind it).
      Process.sleep(20)
      task2 = Task.async(fn -> Http.call(name, "echo", %{}, []) end)

      result1 = Task.await(task1, 5_000)
      result2 = Task.await(task2, 5_000)

      # Both calls trip their per-call read timeout. Transport maps
      # Mint's `:timeout` to `{:error, :timeout, "http read timeout"}`,
      # which `Http.call/4` propagates verbatim (`:timeout` is one of
      # the allowed reasons in the impl's `handle_call/3`).
      assert {:error, :timeout, detail1} = result1
      assert {:error, :timeout, detail2} = result2
      assert is_binary(detail1)
      assert is_binary(detail2)
    end
  end

  # ───────── D. Eager-start integration: 503-at-boot non-fatal ─────────

  describe "eager-start with HTTP upstream that 503s (§4.3)" do
    setup do
      reg_name = :"http-phase2g-reg-#{System.unique_integer([:positive])}"
      Catalog.clear_frozen()

      on_exit(fn ->
        case Process.whereis(reg_name) do
          nil ->
            :ok

          pid ->
            ref = Process.monitor(pid)
            Process.exit(pid, :shutdown)

            receive do
              {:DOWN, ^ref, :process, ^pid, _} -> :ok
            after
              2_000 -> :ok
            end
        end

        Catalog.clear_frozen()
      end)

      {:ok, reg_name: reg_name}
    end

    test "HTTP upstream that 503s at boot renders '(unavailable at startup)'", %{
      reg_name: reg_name
    } do
      %{port: port} = boot_fake(:server_error_5xx)

      bad_name = unique_name("http-bad")

      upstreams = [
        %{
          name: bad_name,
          impl: Http,
          # Tight backoff/timeouts so the eager-start attempt finishes
          # quickly. The handshake will fail at step 1 (initialize
          # returns 503), Connection.ensure_started/1 will report
          # `:upstream_unavailable`, and the supervisor proceeds.
          config:
            config(port, %{
              handshake_timeout_ms: 1_000,
              backoff_initial_ms: 5,
              backoff_max_ms: 50
            })
        }
      ]

      {:ok, _pid} = UpstreamRegistry.start_link(name: reg_name, upstreams: upstreams)

      # Eager-start MUST complete without raising even though the
      # only upstream returns 503 to every request.
      :ok =
        UpstreamSupervisor.eager_start_upstreams(
          upstreams: upstreams,
          registry_name: reg_name
        )

      bad_pid = UpstreamRegistry.connection_for(bad_name, reg_name)
      assert is_pid(bad_pid)

      # Connection still alive, but impl never reached :started —
      # cached_tools is nil, started? is false. This is the spec's
      # "non-fatal degradation" path (§4.3).
      refute Connection.started?(bad_pid)
      assert Connection.cached_tools(bad_pid) == nil

      # Catalog renders the upstream as "(unavailable at startup)".
      catalog = Catalog.render(reg_name)
      assert catalog =~ "#{bad_name}:\n  (unavailable at startup)"
    end
  end

  # ───────── E. Connection-lifecycle integration via Registry ─────────

  describe "Registry → Connection → Http.call/4 end-to-end" do
    setup do
      reg_name = :"http-phase2g-e2e-reg-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        case Process.whereis(reg_name) do
          nil ->
            :ok

          pid ->
            ref = Process.monitor(pid)
            Process.exit(pid, :shutdown)

            receive do
              {:DOWN, ^ref, :process, ^pid, _} -> :ok
            after
              2_000 -> :ok
            end
        end
      end)

      {:ok, reg_name: reg_name}
    end

    test "happy-path tools/call dispatches through Connection to Http impl", %{reg_name: reg_name} do
      toolset = [
        %{
          "name" => "echo",
          "description" => "echoes input",
          "inputSchema" => %{"type" => "object"}
        }
      ]

      %{port: port} = boot_fake(:handshake_success, %{toolset: toolset})

      name = unique_name("http-e2e")

      upstreams = [
        %{
          name: name,
          impl: Http,
          config:
            config(port, %{
              backoff_initial_ms: 10,
              backoff_max_ms: 100
            })
        }
      ]

      {:ok, _pid} = UpstreamRegistry.start_link(name: reg_name, upstreams: upstreams)

      # Drive the same path AggregatorTools / UpstreamCalls runs:
      # routing-Registry lookup → Connection.ensure_started/1 →
      # Connection.call/4 → impl.call/4. The HTTP impl must work
      # through the same dispatch as Stdio.
      conn_pid = UpstreamRegistry.connection_for(name, reg_name)
      assert is_pid(conn_pid)

      assert {:ok, %{duration_ms: _}} = Connection.ensure_started(conn_pid)
      assert Connection.started?(conn_pid)

      # Cached tools propagate from `tools/list` through the impl into
      # the Connection's snapshot.
      assert [%{name: "echo"}] = Connection.cached_tools(conn_pid)

      # tools/call goes Connection.call/4 → impl.call/4 → wire.
      assert {:ok, %{"content" => [%{"type" => "text", "text" => "called echo"}]}} =
               Connection.call(conn_pid, "echo", %{"foo" => "bar"}, [])
    end
  end
end
