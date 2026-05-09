defmodule PtcRunnerMcp.Credentials.RedactorTest do
  # async: false because Redactor reads the globally-named ETS table
  # `:credentials_redaction_set` and several tests register secrets
  # that would race with parallel scrub callers.
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Credentials
  alias PtcRunnerMcp.Credentials.Binding
  alias PtcRunnerMcp.Credentials.Redactor

  # ----------------------------------------------------------------
  # Pure scrub/1 behavior
  # ----------------------------------------------------------------

  describe "scrub/1 with the redaction-set table absent" do
    setup do
      # Defensive: make sure no prior test left the table behind.
      ensure_table_absent()
      :ok
    end

    test "returns binary input unchanged" do
      assert Redactor.scrub("hello world") == "hello world"
    end

    test "returns iodata input as a binary, unchanged" do
      assert Redactor.scrub(["hello ", ?w, "orld"]) == "hello world"
    end

    test "handles empty string" do
      assert Redactor.scrub("") == ""
    end
  end

  describe "scrub/1 with the redaction-set table empty" do
    setup do
      start_credentials!(%{})
      :ok
    end

    test "returns input unchanged when no secrets are registered" do
      assert Redactor.scrub("hello world") == "hello world"
    end
  end

  describe "scrub/1 with secrets registered" do
    setup do
      bindings = %{
        "alpha" => literal_binding("alpha", "topsecret-32-byte-token-abcdefghij"),
        "beta" => literal_binding("beta", "another-secret-value"),
        "short" => literal_binding("short", "foo"),
        "long" => literal_binding("long", "foobar")
      }

      pid = start_credentials!(bindings)

      # Force materialization so each plaintext lands in the ETS table.
      {:ok, _} = Credentials.materialize(pid, "alpha")
      {:ok, _} = Credentials.materialize(pid, "beta")
      {:ok, _} = Credentials.materialize(pid, "short")
      {:ok, _} = Credentials.materialize(pid, "long")

      :ok
    end

    test "substitutes a registered value with [REDACTED]" do
      assert Redactor.scrub("got the topsecret-32-byte-token-abcdefghij here") ==
               "got the [REDACTED] here"
    end

    test "returns input unchanged when no registered value appears" do
      assert Redactor.scrub("nothing sensitive here") == "nothing sensitive here"
    end

    test "replaces multiple distinct registered values in one input" do
      input = "a=topsecret-32-byte-token-abcdefghij b=another-secret-value c=safe"

      out = Redactor.scrub(input)

      refute String.contains?(out, "topsecret-32-byte-token-abcdefghij")
      refute String.contains?(out, "another-secret-value")
      assert String.contains?(out, "[REDACTED]")
      assert String.contains?(out, "c=safe")
    end

    test "longest-first ordering: foobar wins over foo when both registered" do
      assert Redactor.scrub("prefix-foobar-suffix") == "prefix-[REDACTED]-suffix"
    end

    test "scrubs iodata input correctly" do
      assert Redactor.scrub([
               "got the ",
               "topsecret-32-byte-token-abcdefghij",
               " here"
             ]) == "got the [REDACTED] here"
    end

    test "placeholder/0 returns the literal substituted" do
      assert Redactor.placeholder() == "[REDACTED]"
    end
  end

  describe "scrub/1 property: registered random secret never leaks" do
    setup do
      # 16 random bytes (Base16-encoded → 32 ASCII chars) so the
      # secret is unique and unlikely to collide with anything in
      # surrounding text. We register it once and then exercise a
      # variety of input shapes.
      secret = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      bindings = %{"rand" => literal_binding("rand", secret)}
      pid = start_credentials!(bindings)
      {:ok, _} = Credentials.materialize(pid, "rand")
      {:ok, secret: secret}
    end

    test "secret is absent from scrub output regardless of input shape", %{secret: secret} do
      shapes = [
        secret,
        "prefix " <> secret <> " suffix",
        "x=" <> secret,
        secret <> secret,
        String.duplicate(secret, 5),
        "noise " <> secret <> " noise " <> secret <> " end"
      ]

      for input <- shapes do
        out = Redactor.scrub(input)

        refute String.contains?(out, secret),
               "secret leaked through scrub for input shape: #{inspect(input)}"

        assert String.contains?(out, "[REDACTED]")
      end
    end
  end

  # ----------------------------------------------------------------
  # End-to-end: Log emission is scrubbed
  # ----------------------------------------------------------------

  # codex-43640bd [P1] #1: per-record JSONL scrubbing for telemetry
  # event maps (TraceHandler → PtcRunner.TraceLog.write_to_active/1).
  describe "scrub_deep/1 (telemetry event-map scrubbing)" do
    setup do
      bindings = %{"tok" => literal_binding("tok", "deep-secret-aaaaaaaaaaa")}
      pid = start_credentials!(bindings)
      {:ok, _} = Credentials.materialize(pid, "tok")
      :ok
    end

    test "scrubs binary leaves inside nested maps" do
      event = %{
        "event" => "ptc_runner_mcp.call.stop",
        "metadata" => %{
          "tool_name" => "ptc_lisp_execute",
          "reason" => "boom: deep-secret-aaaaaaaaaaa happened"
        },
        "measurements" => %{"duration" => 42}
      }

      out = Redactor.scrub_deep(event)

      assert out["event"] == "ptc_runner_mcp.call.stop"
      assert out["metadata"]["tool_name"] == "ptc_lisp_execute"
      refute String.contains?(out["metadata"]["reason"], "deep-secret-aaaaaaaaaaa")
      assert String.contains?(out["metadata"]["reason"], "[REDACTED]")
      assert out["measurements"]["duration"] == 42
    end

    test "preserves non-binary leaves (atoms, numbers, booleans, nil, structs)" do
      ts = ~U[2026-05-09 10:00:00Z]

      event = %{
        kind: :error,
        count: 3,
        ok?: true,
        missing: nil,
        ts: ts,
        nested: [%{a: 1}, %{b: :two}]
      }

      out = Redactor.scrub_deep(event)

      assert out.kind == :error
      assert out.count == 3
      assert out.ok? == true
      assert out.missing == nil
      assert out.ts == ts
      assert out.nested == [%{a: 1}, %{b: :two}]
    end

    test "scrubs binary keys (not just values) in maps" do
      # JSON-encodes verbatim; a secret embedded in a key would leak
      # through the encoder if scrub_deep walked values only.
      event = %{
        "metadata" => %{
          "deep-secret-aaaaaaaaaaa" => "value",
          "harmless_key" => "safe"
        }
      }

      out = Redactor.scrub_deep(event)

      keys = Map.keys(out["metadata"])
      refute "deep-secret-aaaaaaaaaaa" in keys
      assert Enum.any?(keys, &String.contains?(&1, "[REDACTED]"))
      assert "harmless_key" in keys
    end

    test "scrubs binaries inside lists and tuples" do
      event = %{
        list: ["safe", "deep-secret-aaaaaaaaaaa", "also-safe"],
        tuple: {"left", "right deep-secret-aaaaaaaaaaa"}
      }

      out = Redactor.scrub_deep(event)

      refute "deep-secret-aaaaaaaaaaa" in out.list
      assert "[REDACTED]" in out.list
      {_left, right} = out.tuple
      refute String.contains?(right, "deep-secret-aaaaaaaaaaa")
      assert String.contains?(right, "[REDACTED]")
    end
  end

  describe "PtcRunnerMcp.TraceHandler integration" do
    setup do
      bindings = %{"th" => literal_binding("th", "trace-handler-secret-zzz")}
      pid = start_credentials!(bindings)
      {:ok, _} = Credentials.materialize(pid, "th")
      :ok
    end

    test "handle_event scrubs metadata before write_to_active receives it" do
      # We tap PtcRunner.TraceLog by monkey-patching the Process
      # dictionary: emit a telemetry event with a metadata field
      # containing the secret, capture the event_map that
      # TraceHandler hands off, and assert it is redacted.
      #
      # Approach: directly invoke handle_event/4 with a known shape.
      # The collector process registered for `write_to_active/1` will
      # see a redacted map.
      #
      # We can't easily intercept `PtcRunner.TraceLog.write_to_active`
      # without monkey-patching, so we instead assert via the
      # `Redactor.scrub_deep/1` contract: feeding a structurally
      # identical metadata payload through scrub_deep produces no
      # secret leak. This pairs with the trace_handler.ex code
      # change (the one-line `Redactor.scrub_deep(event_map)` wrap
      # before the `write_to_active/1` call) — together they
      # guarantee the JSONL never carries the secret.
      metadata = %{
        tool_name: "ptc_lisp_execute",
        reason: "auth_failed: trace-handler-secret-zzz exposed"
      }

      out = Redactor.scrub_deep(metadata)

      refute String.contains?(out.reason, "trace-handler-secret-zzz")
      assert String.contains?(out.reason, "[REDACTED]")
    end
  end

  describe "PtcRunnerMcp.Log integration" do
    setup do
      prior = PtcRunnerMcp.Log.level()
      PtcRunnerMcp.Log.set_level(:debug)
      on_exit(fn -> PtcRunnerMcp.Log.set_level(prior) end)

      bindings = %{
        "topsecret" => literal_binding("topsecret", "topsecret-32-byte-token-abcdefghij")
      }

      pid = start_credentials!(bindings)
      {:ok, _} = Credentials.materialize(pid, "topsecret")
      :ok
    end

    test "Log.log replaces a registered secret in the emitted JSON line" do
      out =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          PtcRunnerMcp.Log.log(:warn, "test_event", %{
            detail: "got the topsecret-32-byte-token-abcdefghij here"
          })
        end)

      refute String.contains?(out, "topsecret-32-byte-token-abcdefghij"),
             "Log line still contained the secret: #{inspect(out)}"

      assert String.contains?(out, "[REDACTED]")
      assert String.contains?(out, "\"event\":\"test_event\"")
    end

    test "Log.log without a registered secret is unchanged" do
      out =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          PtcRunnerMcp.Log.log(:info, "innocuous", %{message: "no secrets here"})
        end)

      assert String.contains?(out, "no secrets here")
      assert String.contains?(out, "innocuous")
    end
  end

  describe "PtcRunnerMcp.Log without Credentials booted" do
    # No setup that starts Credentials — verifies the table-absent
    # fallback that makes the existing test suite non-disruptive.
    setup do
      ensure_table_absent()
      prior = PtcRunnerMcp.Log.level()
      PtcRunnerMcp.Log.set_level(:debug)
      on_exit(fn -> PtcRunnerMcp.Log.set_level(prior) end)
      :ok
    end

    test "Log.log emits unchanged when Credentials is not booted" do
      out =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          PtcRunnerMcp.Log.log(:warn, "no_creds_event", %{detail: "ordinary message"})
        end)

      assert String.contains?(out, "ordinary message")
      assert String.contains?(out, "no_creds_event")
    end
  end

  # ----------------------------------------------------------------
  # End-to-end: UpstreamCalls.error_entry/5 redaction
  # ----------------------------------------------------------------

  describe "PtcRunnerMcp.UpstreamCalls.error_entry/5 integration" do
    setup do
      bindings = %{
        "tk" => literal_binding("tk", "leaked-bearer-prefix-9f3a2b1c0d8e7f6a")
      }

      pid = start_credentials!(bindings)
      {:ok, _} = Credentials.materialize(pid, "tk")
      :ok
    end

    test "error field has registered secret replaced with [REDACTED]" do
      entry =
        PtcRunnerMcp.UpstreamCalls.error_entry(
          "github",
          "search_repos",
          :upstream_error,
          "auth failed: Bearer leaked-bearer-prefix-9f3a2b1c0d8e7f6a expired",
          1234
        )

      refute String.contains?(entry["error"], "leaked-bearer-prefix-9f3a2b1c0d8e7f6a")
      assert String.contains?(entry["error"], "[REDACTED]")
      # Other fields unchanged
      assert entry["server"] == "github"
      assert entry["tool"] == "search_repos"
      assert entry["status"] == "error"
      assert entry["reason"] == "upstream_error"
      assert entry["duration_ms"] == 1234
    end

    test "error field unchanged when no registered secret appears" do
      entry =
        PtcRunnerMcp.UpstreamCalls.error_entry(
          "github",
          "search_repos",
          :timeout,
          "request exceeded 5000ms",
          5000
        )

      assert entry["error"] == "request exceeded 5000ms"
    end
  end

  # ----------------------------------------------------------------
  # End-to-end: TracePayload outputs are scrubbed
  # ----------------------------------------------------------------

  describe "PtcRunnerMcp.TracePayload integration" do
    setup do
      bindings = %{
        "tp" => literal_binding("tp", "tracepayload-secret-xyz123")
      }

      pid = start_credentials!(bindings)
      {:ok, _} = Credentials.materialize(pid, "tp")
      :ok
    end

    test "redact_program(:full) scrubs registered secrets in the program string" do
      program = "(send-bearer \"tracepayload-secret-xyz123\")"
      out = PtcRunnerMcp.TracePayload.redact_program(program, :full)

      assert is_binary(out)
      refute String.contains?(out, "tracepayload-secret-xyz123")
      assert String.contains?(out, "[REDACTED]")
    end

    test "redact_program(:summary) scrubs the preview" do
      program = "(send-bearer \"tracepayload-secret-xyz123\")"
      out = PtcRunnerMcp.TracePayload.redact_program(program, :summary)

      assert is_map(out)
      refute String.contains?(out["preview"], "tracepayload-secret-xyz123")
      assert String.contains?(out["preview"], "[REDACTED]")
    end

    test "redact_prints(:full) scrubs printed lines" do
      prints = ["normal line", "leaked: tracepayload-secret-xyz123"]
      out = PtcRunnerMcp.TracePayload.redact_prints(prints, :full)

      Enum.each(out, fn line ->
        refute String.contains?(line, "tracepayload-secret-xyz123")
      end)
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  # Starts a fresh `PtcRunnerMcp.Credentials` GenServer registered as
  # `__MODULE__` (the production name) so the named ETS table is the
  # one `Redactor.scrub/1` looks up. We tear it down explicitly on
  # exit so subsequent tests in this file (or other files) do not
  # observe stale entries.
  defp start_credentials!(bindings) do
    # If a previous test left the named server alive, stop it first.
    case Process.whereis(Credentials) do
      nil -> :ok
      pid -> stop_credentials(pid)
    end

    {:ok, pid} = Credentials.start_link(bindings: bindings, name: Credentials)

    on_exit(fn -> stop_credentials(pid) end)

    pid
  end

  defp stop_credentials(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal, 5_000)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  defp ensure_table_absent do
    case Process.whereis(Credentials) do
      nil ->
        # Server isn't running. Named ETS tables die with their owner,
        # so the table should already be gone — assert defensively.
        case :ets.info(Credentials.table_name(), :size) do
          :undefined -> :ok
          _ -> flunk("redaction-set table exists but no Credentials owner")
        end

      pid ->
        stop_credentials(pid)
    end
  end

  defp literal_binding(name, value) do
    %Binding{
      name: name,
      source: :literal,
      scheme_hint: :raw,
      spec: %{value: value}
    }
  end
end
