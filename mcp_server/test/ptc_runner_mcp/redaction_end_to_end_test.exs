defmodule PtcRunnerMcp.RedactionEndToEndTest do
  @moduledoc """
  Stream 3D — load-bearing **property test** for the §4.2 / §7.5.3
  structural-isolation guarantee: a resolved auth secret MUST NOT
  appear in any of the four operator-visible emission surfaces over
  a full handshake-and-call cycle.

  Per `Plans/http-transport-credentials.md` §13.3:

  > `RedactionEndToEndTest` — token byte sequence absent from JSONL
  > trace files, `upstream_calls` envelope, log capture buffer for a
  > full handshake-and-call cycle.

  ## Adversarial framing

  The test is written to find leak paths that the structural impl
  did not anticipate. Each of `N >= 8` cycles spawns a **fresh
  per-cycle universe** (unique secret, unique Credentials instance,
  unique FakeHttpServer, unique trace dir, unique upstream name). No
  state survives between cycles — a bug that contaminates ETS,
  persistent_term, or named ETS across cycles must show up as a
  hit in cycle N+1.

  ## What we assert per cycle

  For a randomly generated 32-byte (64 hex chars) secret bound to
  `bearer` auth and exercised over `initialize` →
  `notifications/initialized` → `tools/list` → `tools/call`:

    1. Secret bytes ABSENT from captured stderr (every `Log.log`
       emission, level set to `:debug` so even the lowest-priority
       events surface).
    2. Secret bytes ABSENT from every JSONL file written under the
       per-cycle trace dir (concatenated; covers handshake,
       per-event telemetry, and the final envelope).
    3. Secret bytes ABSENT from a `UpstreamCalls.error_entry/5`
       constructed from a synthetic transport error whose `detail`
       embeds the secret verbatim — this is the worst-case
       world-fault path (a misbehaving HTTP transport could echo
       the bearer prefix back through a caught exception's message).
    4. Secret bytes ABSENT from `inspect(:sys.get_state(impl_pid))`
       with `limit: :infinity, printable_limit: :infinity` — defends
       against a future refactor that accidentally caches the
       resolved value somewhere reachable from the impl GenServer's
       state.
    5. The redactor placeholder string `"[REDACTED]"` IS present in
       at least one of stderr OR upstream_calls.error — this proves
       the redactor is actually FIRING on registered values, not
       merely that the secret never made it to those surfaces (a
       bug-shaped no-op redactor would also pass the absence
       assertions, which is a load-bearing distinction §7.5 calls
       out).

  ## Why we use the canonical `PtcRunnerMcp.Credentials` name

  `Credentials.Redactor.scrub/1` reads the **named** ETS table
  `:credentials_redaction_set`. A test instance started under a
  unique name gets a *private, unnamed* ETS (see
  `lib/ptc_runner_mcp/credentials.ex:258`); the redactor cannot find
  it, and `scrub/1` returns its input unchanged. To exercise the
  full redaction path end-to-end (the load-bearing claim), we
  serialize cycles through one canonical `Credentials` GenServer
  with the production name, restarting it per cycle so each gets a
  fresh ETS table. This matches the production wire-up exactly.

  Spec: `Plans/http-transport-credentials.md` §4.2, §7.5.1, §7.5.3,
  §13.3, Phase 3 §12.

  `:async: false` — single ownership of the named ETS redaction
  table; we serialize cycles within this test.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Credentials
  alias PtcRunnerMcp.Credentials.Binding
  alias PtcRunnerMcp.{Log, TraceConfig, TraceFile, TraceHandler, UpstreamCalls}
  alias PtcRunnerMcp.Test.FakeHttpServer
  alias PtcRunnerMcp.Upstream.Http

  @n_cycles 16

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  setup do
    # Snapshot every piece of process-wide state we touch so on_exit
    # restores the test suite's invariants.
    original_trace_config = TraceConfig.get()
    original_log_level = Log.level()

    # Make sure no prior canonical Credentials instance is alive — a
    # leftover would carry stale ETS rows and false-positive our
    # presence checks (see assertions about `[REDACTED]`).
    stop_canonical_credentials!()

    on_exit(fn ->
      stop_canonical_credentials!()
      TraceHandler.detach()
      TraceConfig.set(original_trace_config)
      Log.set_level(original_log_level)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # The property test
  # ---------------------------------------------------------------------------

  describe "redaction property over randomized 32-byte secrets" do
    test "secret bytes absent from logs, JSONL traces, upstream_calls, and impl state across #{@n_cycles} cycles" do
      # Maximum log emission — the redactor's defense-in-depth claim
      # is "every binary that flows through Log.log/3", so set the
      # threshold to the lowest level. Captures `:debug` events that
      # the default `:info` would silently drop.
      Log.set_level(:debug)

      results =
        for cycle <- 1..@n_cycles do
          run_cycle(cycle)
        end

      # Aggregate so a single test failure points at the offending
      # cycle, but a clean run also confirms `[REDACTED]` showed up
      # somewhere across cycles (the redactor positively fired).
      Enum.each(results, &assert_no_leak/1)

      # Cross-cycle sanity: at least ONE cycle produced visible
      # `[REDACTED]` evidence. If every cycle was redactor-silent
      # then the absence assertions are passing only because the
      # secret never made it through the path at all (a regression
      # that disables the codepath would still pass without this).
      any_redacted? =
        Enum.any?(results, fn r ->
          String.contains?(r.stderr, "[REDACTED]") or
            String.contains?(r.upstream_calls_error_field, "[REDACTED]")
        end)

      assert any_redacted?,
             "no cycle observed a `[REDACTED]` substitution — redactor may be inert"
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry handler payload — the structural-isolation guarantee
  # extends to telemetry metadata (§7.5.3 (a)). Operator-installed
  # handlers are a separate leak surface; the redactor can't reach
  # them. Verify metadata never CARRIES the resolved secret.
  # ---------------------------------------------------------------------------

  describe "telemetry handler payloads (§7.5.3 (a) structural isolation)" do
    test "[:ptc_lisp, :upstream, :http, :sse_array_compat] metadata never carries the secret" do
      secret = generate_secret()
      universe = build_universe(secret, :handshake_success)

      handler_id = "redaction-test-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [
          [:ptc_lisp, :upstream, :http, :sse_array_compat],
          [:ptc_lisp, :upstream, :http, :request, :stop],
          [:ptc_lisp, :upstream, :auto_decode, :stop]
        ],
        &__MODULE__.telemetry_capture/4,
        %{test_pid: test_pid}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Drive a `tools/call` so any `:upstream` telemetry events fire.
      assert {:ok, _pid} =
               Http.start_link(universe.upstream_name, universe.http_config)

      on_exit(fn -> safe_stop_http(universe.upstream_name) end)

      assert {:ok, _result} = Http.call(universe.upstream_name, "echo", %{}, [])

      # Drain captured telemetry. We don't care which events fire —
      # just that none carry the secret in measurements or metadata.
      events = drain_telemetry()

      for {event, measurements, metadata} <- events do
        m_str = inspect(measurements, limit: :infinity, printable_limit: :infinity)
        meta_str = inspect(metadata, limit: :infinity, printable_limit: :infinity)

        refute String.contains?(m_str, secret),
               "telemetry event #{inspect(event)} measurements leaked the secret"

        refute String.contains?(meta_str, secret),
               "telemetry event #{inspect(event)} metadata leaked the secret"
      end

      teardown_universe(universe)
    end
  end

  # ---------------------------------------------------------------------------
  # Stack-trace surface from a deliberately raised exception
  # ---------------------------------------------------------------------------

  describe "stack traces from a deliberately raised exception in the request path" do
    @tag :skip
    test "documented gap: no scenario currently produces a malformed-JSON post-handshake response" do
      # The `Plans/http-transport-credentials.md` Phase 3 codex
      # challenge brief calls out "stack traces from a deliberately
      # raised exception in the request path" as a leak surface to
      # exercise. The available `FakeHttpServer` scenarios all return
      # well-formed JSON-RPC bodies (success, JSON-RPC error 4xx,
      # 401/403, session-loss, timeout, malformed handshake — but no
      # post-handshake malformed-JSON path).
      #
      # Adding a `:tools_call_malformed_json` scenario to the fixture
      # would let us trigger `Jason.decode/1` raising in the request
      # path and exercise the resulting stack-trace formatting through
      # `Logger.report` / `:error_logger`. That fixture extension is
      # out-of-scope for 3D; a follow-up Phase 3 ticket should add it
      # so this gap is closed before the §12 Phase 3 codex review.
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Per-cycle universe construction & assertion helpers
  # ---------------------------------------------------------------------------

  defp run_cycle(cycle) do
    secret = generate_secret()
    universe = build_universe(secret, :handshake_success, cycle: cycle)

    {{trace_files_concat, error_entry, impl_state_str}, stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        # Wrap the entire start + call lifecycle in
        # `TraceFile.with_traced_call/4` so JSONL files actually get
        # written under our trace dir. The `with_traced_call/4` hook
        # is the production wiring point — anything not flowing
        # through it would not land in JSONL in real operation either,
        # so testing only the in-band path matches deployment.
        request_id = "redact-test-#{cycle}"

        envelope =
          TraceFile.with_traced_call(request_id, "(test program)", [], fn ->
            assert {:ok, pid} =
                     Http.start_link(universe.upstream_name, universe.http_config)

            assert {:ok, _result} = Http.call(universe.upstream_name, "echo", %{}, [])

            # Snapshot impl state BEFORE stop. Any leak via
            # GenServer state would surface here. `inspect/2` with
            # both limits set to :infinity walks the entire state
            # tree, including nested structs (Session, snapshot
            # remnants, etc.).
            state_str =
              :sys.get_state(pid)
              |> inspect(limit: :infinity, printable_limit: :infinity)

            safe_stop_http(universe.upstream_name)

            # Return a synthetic envelope so `TraceFile` can name
            # the JSONL file and we exercise the on-success path.
            %{
              "isError" => false,
              "content" => [%{"type" => "text", "text" => "ok"}],
              "_state_str" => state_str
            }
          end)

        impl_state_str = Map.fetch!(envelope, "_state_str")

        # Construct an `UpstreamCalls.error_entry/5` whose detail
        # embeds the secret verbatim. This simulates the worst-case
        # transport-error path — e.g. a Req exception whose message
        # echoes back a leaked `Authorization: Bearer <secret>`
        # prefix. The error_entry/5 builder is the production
        # construction point for the `upstream_calls` envelope's
        # error field; its scrub/1 of `detail` is the only line of
        # defense for that specific shape.
        error_entry =
          UpstreamCalls.error_entry(
            "test-server-#{cycle}",
            "echo",
            :upstream_unavailable,
            "transport error: leaked-bearer-prefix " <> secret <> " trailing context",
            42
          )

        # Concatenate every JSONL file under the trace dir. There may
        # be multiple (handshake header, per-event lines) — we treat
        # them as one big haystack.
        trace_files_concat = read_all_trace_files(universe.trace_dir)

        {trace_files_concat, error_entry, impl_state_str}
      end)

    teardown_universe(universe)

    %{
      cycle: cycle,
      secret: secret,
      stderr: stderr,
      trace_files_concat: trace_files_concat,
      upstream_calls_error_field: Map.fetch!(error_entry, "error"),
      upstream_calls_entry_inspect: inspect(error_entry, limit: :infinity),
      impl_state_str: impl_state_str
    }
  end

  defp assert_no_leak(%{
         cycle: cycle,
         secret: secret,
         stderr: stderr,
         trace_files_concat: trace,
         upstream_calls_error_field: uc_error,
         upstream_calls_entry_inspect: uc_entry,
         impl_state_str: impl_state
       }) do
    # First 8 hex chars of the secret. Used in failure messages so a
    # diagnostic doesn't itself leak the rest of the secret bytes.
    fingerprint = String.slice(secret, 0, 8)

    refute String.contains?(stderr, secret),
           "cycle #{cycle}: stderr leaked secret prefix #{fingerprint}…"

    refute String.contains?(trace, secret),
           "cycle #{cycle}: trace JSONL leaked secret prefix #{fingerprint}…"

    refute String.contains?(uc_error, secret),
           "cycle #{cycle}: upstream_calls.error leaked secret prefix #{fingerprint}…"

    refute String.contains?(uc_entry, secret),
           "cycle #{cycle}: upstream_calls entry inspect leaked secret prefix #{fingerprint}…"

    refute String.contains?(impl_state, secret),
           "cycle #{cycle}: impl GenServer state leaked secret prefix #{fingerprint}…"
  end

  # 32 random bytes encoded as 64 hex chars. Lowercase so it cannot
  # accidentally collide with case-folded "REDACTED" / "Bearer "
  # noise. Uniqueness across cycles is guaranteed by 256 bits of
  # entropy.
  defp generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  defp build_universe(secret, scenario, opts \\ []) do
    cycle = Keyword.get(opts, :cycle, 0)

    creds_pid = start_canonical_credentials!(%{"tok" => literal_binding("tok", secret)})

    %{server: server, port: port} =
      boot_fake(scenario, %{toolset: toolset(), id: cycle})

    upstream_name = "redact-cycle-#{cycle}-#{System.unique_integer([:positive])}"

    trace_dir =
      Path.join(System.tmp_dir!(), "redact-test-#{cycle}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(trace_dir)

    cfg = %{
      trace_dir: trace_dir,
      trace_payloads: :full,
      trace_max_files: 1000
    }

    :ok = TraceConfig.set(cfg)
    :ok = TraceHandler.attach()

    http_config = %{
      url: "http://127.0.0.1:#{port}/mcp",
      handshake_timeout_ms: 2_000,
      request_timeout_ms: 2_000,
      connect_timeout_ms: 1_000,
      max_response_bytes: 256 * 1024,
      pool_size: 2,
      auth: [%{scheme: :bearer, binding: "tok", header: nil}],
      credentials: creds_pid
    }

    %{
      creds_pid: creds_pid,
      server: server,
      port: port,
      upstream_name: upstream_name,
      trace_dir: trace_dir,
      http_config: http_config
    }
  end

  defp teardown_universe(universe) do
    safe_stop_http(universe.upstream_name)
    TraceHandler.detach()
    File.rm_rf!(universe.trace_dir)
    stop_canonical_credentials!()
  end

  defp boot_fake(scenario, opts) do
    server =
      start_supervised!(
        {FakeHttpServer, scenario: scenario, opts: opts},
        id: {FakeHttpServer, System.unique_integer([:positive])}
      )

    %{server: server, port: FakeHttpServer.port(server)}
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

  defp literal_binding(name, value) do
    %Binding{
      name: name,
      source: :literal,
      scheme_hint: nil,
      spec: %{value: value}
    }
  end

  # ---------------------------------------------------------------------------
  # Canonical Credentials lifecycle
  # ---------------------------------------------------------------------------

  defp start_canonical_credentials!(bindings) do
    stop_canonical_credentials!()

    {:ok, pid} = Credentials.start_link(bindings: bindings, name: Credentials)
    pid
  end

  defp stop_canonical_credentials! do
    case Process.whereis(Credentials) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end
    end
  end

  defp safe_stop_http(name) do
    Http.stop(name)
  catch
    :exit, _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Trace-file aggregation
  # ---------------------------------------------------------------------------

  defp read_all_trace_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map_join("\n", fn name ->
          dir |> Path.join(name) |> File.read!()
        end)

      {:error, _} ->
        ""
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry-mailbox helpers
  # ---------------------------------------------------------------------------

  @doc false
  # Public seam so `:telemetry.attach_many/4` can capture this MFA
  # without the local-function warning. Forwards every event to the
  # configured `:test_pid` mailbox.
  def telemetry_capture(event, measurements, metadata, %{test_pid: pid}) do
    send(pid, {:telemetry, event, measurements, metadata})
    :ok
  end

  defp drain_telemetry, do: drain_telemetry([])

  defp drain_telemetry(acc) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        drain_telemetry([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
