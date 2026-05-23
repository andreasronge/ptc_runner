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
    * Concurrent callers run in parallel (impl mailbox does NOT
      serialize) and `pool_size: 1` queues at Finch — not at the
      impl GenServer.
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
          [:ptc_lisp, :upstream, :http, :sse_array_compat],
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
      assert_receive {:telemetry_event, [:ptc_lisp, :upstream, :http, :sse_array_compat],
                      %{count: 1}, _metadata},
                     1_000

      refute_received {:telemetry_event, [:ptc_lisp, :upstream, :http, :sse_array_compat], _, _}
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

  # ───────── C. Concurrent callers against a slow upstream ─────────
  #
  # Per `Plans/http-transport-credentials.md` §§4.1, 6.5, 10:
  # `Upstream.Http.call/4` MUST run `Transport.post/1` from the caller
  # process so multiple in-flight `tools/call` invocations against the
  # same upstream proceed in parallel. The impl GenServer is consulted
  # only for a fast `:checkout_request` mailbox call (id allocation +
  # config snapshot).
  #
  # The codex P1 fix for commit `76f68de` resolved this — before the
  # fix, every `tools/call` funnelled through one blocking
  # `GenServer.call(pid, {:tools_call, ...})`, which serialized
  # concurrent callers and made `:pool_size` effectively ignored. The
  # tests below pin both the parallelism and the per-pool queueing
  # behaviour.
  describe "concurrent callers run in parallel (impl mailbox does NOT serialize)" do
    test "two concurrent slow calls each finish in ~delay_ms (proves parallel dispatch)" do
      delay_ms = 400
      %{port: port} = boot_fake(:tools_call_slow, %{delay_ms: delay_ms})

      name = unique_name("http-slow-parallel")

      assert {:ok, _pid} =
               Http.start_link(
                 name,
                 config(port, %{
                   # `pool_size: 4` — both concurrent requests can hold
                   # their own Finch connection at once. If the impl
                   # serialized at its mailbox (the pre-fix bug), the
                   # second call would not start until the first
                   # finished, doubling the observed latency.
                   pool_size: 4,
                   handshake_timeout_ms: 5_000,
                   request_timeout_ms: 5_000
                 })
               )

      on_exit(fn -> safe_stop(name) end)

      t0 = System.monotonic_time(:millisecond)

      task1 = Task.async(fn -> Http.call(name, "echo", %{}, []) end)
      task2 = Task.async(fn -> Http.call(name, "echo", %{}, []) end)

      assert {:ok, _} = Task.await(task1, 5_000)
      assert {:ok, _} = Task.await(task2, 5_000)

      elapsed = System.monotonic_time(:millisecond) - t0

      # Two parallel calls of `delay_ms` each should complete in ~delay_ms
      # wall-clock. Allow generous slack for handshake / GenServer hops
      # but reject anything close to `2 * delay_ms` (the serial bound).
      # Threshold: less than 1.7× delay_ms.
      assert elapsed < trunc(delay_ms * 1.7),
             "concurrent calls took #{elapsed}ms (expected near #{delay_ms}ms; " <>
               "near #{2 * delay_ms}ms would mean impl mailbox is serializing)"
    end

    test "pool_size: 1 with a slow upstream — second request queues at Finch" do
      delay_ms = 300
      %{port: port} = boot_fake(:tools_call_slow, %{delay_ms: delay_ms})

      name = unique_name("http-pool1-queue")

      assert {:ok, _pid} =
               Http.start_link(
                 name,
                 config(port, %{
                   pool_size: 1,
                   handshake_timeout_ms: 5_000,
                   request_timeout_ms: 5_000
                 })
               )

      on_exit(fn -> safe_stop(name) end)

      t0 = System.monotonic_time(:millisecond)

      task1 = Task.async(fn -> Http.call(name, "echo", %{}, []) end)
      # Stagger so task1 reaches Finch first.
      Process.sleep(20)
      task2 = Task.async(fn -> Http.call(name, "echo", %{}, []) end)

      assert {:ok, _} = Task.await(task1, 5_000)
      assert {:ok, _} = Task.await(task2, 5_000)

      elapsed = System.monotonic_time(:millisecond) - t0

      # `pool_size: 1`: the second request queues at the Finch pool,
      # not at the impl mailbox. Both succeed but elapsed is ~2 ×
      # delay_ms because the second request can only start after the
      # first releases its connection. This pins the §4.1 invariant
      # that pool_size IS the queueing knob for HTTP upstreams.
      assert elapsed >= delay_ms * 2 - 100,
             "pool_size:1 expected serial queueing (~#{2 * delay_ms}ms); got #{elapsed}ms"
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
      # Per §9.1 (http-transport-credentials.md), the per-server
      # header gains a `[transport: http]` tag for HTTP upstreams —
      # the placeholder body itself is unchanged.
      catalog = Catalog.render(reg_name)
      assert catalog =~ "#{bad_name} [transport: http]:\n  (unavailable at startup)"
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
