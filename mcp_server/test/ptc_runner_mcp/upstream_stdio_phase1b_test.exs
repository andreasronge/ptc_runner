defmodule PtcRunnerMcp.UpstreamStdioPhase1bTest do
  @moduledoc """
  Phase 1b tests for `PtcRunnerMcp.Upstream.Stdio` against the
  mock subprocess fixture in `test/support/mock_server.exs`.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §6.3, §13.3.

  Covers:

    * Handshake order: `initialize` → `notifications/initialized`
      → `tools/list`. The mock server enforces "tools/call before
      initialized → JSON-RPC error" via `MOCK_REQUIRE_INITIALIZED=1`.
    * Happy-path `tools/call` round-trip.
    * JSON-RPC error response → `{:error, :upstream_error, _}`.
    * Per-call timeout enforced.
    * Oversized response rejected (size cap).
    * Subprocess crash mid-call → `{:error, :upstream_unavailable, _}`.
    * Graceful shutdown closes the subprocess via stdin EOF.

  Each test starts its own Stdio GenServer with a unique upstream
  name (so the `Upstream.Stdio.Names` Registry can hold concurrent
  instances) and tears it down on exit.
  """
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Upstream.{Connection, Stdio}

  @mock_path "test/support/mock_server.exs"

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp project_root do
    # The mcp_server Mix project root — same dir as `mix.exs`. Tests
    # run with cwd = `mcp_server/`, so `File.cwd!/0` works.
    File.cwd!()
  end

  defp base_config(env \\ %{}) do
    %{
      command: "mix",
      args: ["run", "--no-start", "--no-compile", @mock_path],
      env: env,
      cd: project_root(),
      handshake_timeout_ms: 15_000
    }
  end

  defp start_stdio!(name, config) do
    {:ok, pid} = Stdio.start_link(name, config)
    on_exit_stop(name, pid)
    pid
  end

  defp on_exit_stop(name, _pid) do
    ExUnit.Callbacks.on_exit(fn ->
      try do
        Stdio.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  @opts [timeout: 10_000, max_response_bytes: 1_000_000]

  describe "handshake (§6.3 invariant)" do
    @tag timeout: 30_000
    test "initialize → notifications/initialized → tools/list happy path" do
      name = unique_name("happy")
      _pid = start_stdio!(name, base_config())

      assert {:ok, schemas} = Stdio.list_tools(name)
      tool_names = Enum.map(schemas, & &1.name) |> Enum.sort()
      assert "echo" in tool_names
      assert "slow" in tool_names
    end

    @tag timeout: 30_000
    test "subprocess that requires notifications/initialized: handshake satisfies it" do
      # `MOCK_REQUIRE_INITIALIZED=1` rejects any `tools/call` until
      # the notification has been observed. If our handshake sent
      # `tools/list` BEFORE the notification (or skipped the
      # notification), the upstream would reject the post-handshake
      # `tools/call`. Asserting the call succeeds proves the
      # ordering.
      name = unique_name("require-init")
      _pid = start_stdio!(name, base_config(%{"MOCK_REQUIRE_INITIALIZED" => "1"}))

      assert {:ok, _result} =
               Stdio.call(name, "echo", %{"msg" => "hi"}, @opts)
    end

    @tag timeout: 30_000
    test "initialize JSON-RPC error → start_link fails with :upstream_unavailable" do
      name = unique_name("init-fail")

      assert {:error, {:upstream_unavailable, detail}} =
               Stdio.start_link(name, base_config(%{"MOCK_INIT_FAIL" => "1"}))

      assert detail =~ "mock initialize failure"
    end
  end

  describe "tools/call round-trip" do
    @tag timeout: 30_000
    test "successful call returns the upstream's result map" do
      name = unique_name("call-ok")
      _pid = start_stdio!(name, base_config())

      assert {:ok, result} = Stdio.call(name, "echo", %{"msg" => "hi"}, @opts)
      assert is_map(result)
      assert result["isError"] == false
      assert result["structuredContent"] == %{"msg" => "hi"}
    end

    @tag timeout: 30_000
    test "JSON-RPC error response → {:error, :upstream_error, detail}" do
      name = unique_name("call-err")

      _pid =
        start_stdio!(name, base_config(%{"MOCK_TOOL_ERROR" => "tool failed: 404 Not Found"}))

      assert {:error, :upstream_error, detail} =
               Stdio.call(name, "echo", %{}, @opts)

      assert detail =~ "404 Not Found"
    end
  end

  describe ":timeout enforcement (§6.3)" do
    @tag timeout: 30_000
    test "per-call timeout fires before the slow upstream replies" do
      # 200ms upstream delay vs 50ms call-side timeout: the Stdio
      # impl MUST surface :timeout deterministically. The 4× margin
      # makes the assertion robust to scheduler jitter.
      name = unique_name("call-timeout")
      _pid = start_stdio!(name, base_config(%{"MOCK_TOOL_DELAY_MS" => "500"}))

      started = System.monotonic_time(:millisecond)

      result =
        Stdio.call(name, "echo", %{}, timeout: 50, max_response_bytes: 1_000_000)

      elapsed = System.monotonic_time(:millisecond) - started

      assert {:error, :timeout, _detail} = result
      assert elapsed < 400, "expected timeout < 400ms, got #{elapsed}ms"
    end
  end

  describe ":max_response_bytes enforcement (§6.3)" do
    @tag timeout: 30_000
    test "oversized response → {:error, :response_too_large, _}" do
      # Mock returns a 5KB payload; cap is 100B. The Stdio impl
      # MUST reject before/at decode and surface
      # `:response_too_large`.
      name = unique_name("call-oversize")
      _pid = start_stdio!(name, base_config(%{"MOCK_OVERSIZED_RESPONSE" => "5000"}))

      assert {:error, :response_too_large, _detail} =
               Stdio.call(name, "big", %{}, timeout: 5_000, max_response_bytes: 100)
    end
  end

  describe "subprocess crash detection" do
    @tag timeout: 30_000
    test "subprocess crash mid-call → {:error, :upstream_unavailable, _}" do
      # The mock crashes (System.halt(1)) on the first `tools/call`.
      # The Stdio impl detects the Port's `:exit_status` message,
      # fails any in-flight callers with `:upstream_unavailable`,
      # and stops the GenServer with an abnormal reason
      # `{:upstream_exited, status}`. The owning Connection observes
      # `:DOWN` and arms its backoff (codex [P2] fix).
      #
      # The test process traps exits because `Stdio.start_link/2`
      # links us to the GenServer, and the GenServer's abnormal
      # stop would otherwise propagate and kill the test. In
      # production the Connection traps exits for the same reason.
      Process.flag(:trap_exit, true)

      name = unique_name("call-crash")

      pid =
        start_stdio!(
          name,
          base_config(%{"MOCK_CRASH_ON_CALL" => "1", "MOCK_CRASH_DELAY_MS" => "50"})
        )

      caller = self()

      stdio_ref = Process.monitor(pid)

      _task =
        Task.async(fn ->
          send(caller, {:result, Stdio.call(name, "echo", %{}, @opts)})
        end)

      assert_receive {:result, {:error, :upstream_unavailable, _detail}}, 10_000

      # Codex review of `3c2754d` flagged a [P2]: pre-fix the
      # GenServer always stopped with `:normal`, so the owning
      # Connection's `abnormal_exit?/1` classified the death as a
      # clean shutdown and skipped the backoff window. Post-fix
      # `:exit_status n != 0` produces `{:upstream_exited, n}` —
      # `abnormal_exit?/1` returns true, the Connection arms
      # backoff. Discriminate here by asserting the DOWN reason
      # carries the non-zero exit status.
      assert_receive {:DOWN, ^stdio_ref, :process, ^pid, reason}, 10_000

      assert match?({:upstream_exited, _}, reason),
             "expected {:upstream_exited, _} (non-zero subprocess exit), got: #{inspect(reason)}"

      assert {:upstream_exited, n} = reason
      assert is_integer(n) and n != 0
    end
  end

  describe "Connection backoff via Stdio crash (codex [P2] regression)" do
    @tag timeout: 30_000
    test "non-zero subprocess exit arms Connection's recovery-backoff window" do
      # Full integration: a Connection wraps a Stdio that crashes
      # mid-call with status 1. The Connection MUST observe
      # `:DOWN` with an abnormal reason and arm its backoff
      # window. The next `ensure_started/1` during the window
      # MUST return `{:error, :upstream_unavailable, "in recovery", _}`
      # without spawning a new subprocess.
      #
      # Pre-fix: Stdio stopped with `:normal` regardless of exit
      # status; Connection saw `:normal` (clean shutdown), did NOT
      # arm backoff, and the next `ensure_started/1` immediately
      # spawned a fresh subprocess. The discriminating assertion is
      # "in recovery" + a counter on subprocess starts.
      name = unique_name("backoff-via-stdio")

      config =
        base_config(%{
          "MOCK_CRASH_ON_CALL" => "1",
          "MOCK_CRASH_DELAY_MS" => "50"
        })
        |> Map.put(:backoff_initial_ms, 10_000)

      {:ok, conn_pid} =
        Connection.start_link({name, Stdio, config})

      ExUnit.Callbacks.on_exit(fn ->
        try do
          Connection.stop(conn_pid)
        catch
          :exit, _ -> :ok
        end

        Stdio.stop(name)
      end)

      assert {:ok, _} = Connection.ensure_started(conn_pid)

      # Capture the Stdio pid + monitor it from the test so we can
      # synchronize on its death before observing the Connection's
      # post-DOWN state.
      stdio_pid = Connection.snapshot(conn_pid).pid
      assert is_pid(stdio_pid)
      stdio_ref = Process.monitor(stdio_pid)

      # Trigger the crash via a `tools/call`. The Stdio GenServer
      # exits with `{:upstream_exited, 1}`; the Connection's
      # monitor `:DOWN` handler arms backoff.
      assert {:error, :upstream_unavailable, _} =
               Connection.call(conn_pid, "echo", %{}, @opts)

      # Wait for the Stdio's death. The BEAM sends `:DOWN` to all
      # monitors atomically when reaping a process; once we've
      # received OUR `:DOWN`, the Connection's `:DOWN` is also
      # already in its mailbox. A subsequent `GenServer.call`
      # therefore arrives FIFO-after the `:DOWN` handler runs and
      # arms backoff.
      assert_receive {:DOWN, ^stdio_ref, :process, ^stdio_pid, reason}, 5_000

      assert match?({:upstream_exited, _}, reason),
             "expected non-zero exit reason, got: #{inspect(reason)}"

      # In the backoff window: ensure_started/1 returns
      # `:upstream_unavailable, "in recovery"` WITHOUT a fresh
      # subprocess spawn. Pre-fix the abnormal exit was lost; this
      # call would have spawned a fresh subprocess and either
      # succeeded or hit MOCK_CRASH_ON_CALL again.
      assert {:error, :upstream_unavailable, "in recovery", _} =
               Connection.ensure_started(conn_pid)
    end
  end

  describe "graceful shutdown via stdin EOF" do
    @tag timeout: 30_000
    test "Stdio.stop/1 closes the Port and the subprocess exits" do
      name = unique_name("stop")
      pid = start_stdio!(name, base_config())

      ref = Process.monitor(pid)

      :ok = Stdio.stop(name)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end

    test "stop/1 is idempotent on a missing upstream" do
      assert :ok = Stdio.stop("never-started-#{System.unique_integer([:positive])}")
    end
  end

  describe "parent EXIT propagation (codex [P2] #2 regression)" do
    @tag timeout: 30_000
    test "Stdio stops cleanly when its parent dies, freeing the Names registration" do
      # Codex review of `fe72ff6` flagged that without a parent-EXIT
      # handler, a Connection killed before its `terminate/2` runs
      # `Stdio.stop/1` leaves the Stdio GenServer running, the
      # subprocess leaked, and the `Stdio.Names` registration
      # occupied — future `start_link/2` for the same upstream
      # returns `{:already_started, _}`.
      #
      # Discriminating signal: after killing the parent (which is
      # also the linked starter of the Stdio), assert
      #   1. The Stdio process exits within ~1s (well before the
      #      5s GenServer.stop timeout).
      #   2. A FRESH `Stdio.start_link/2` for the same upstream
      #      name succeeds — pre-fix it would return
      #      `{:already_started, _}` because the leaked GenServer
      #      still holds the Names registration.
      Process.flag(:trap_exit, true)
      name = unique_name("parent-exit")

      # Spawn an intermediary process whose ONLY job is to start
      # the Stdio (and therefore link to it). When this process
      # dies, the Stdio receives a parent EXIT — the path codex
      # flagged.
      caller = self()

      parent =
        spawn(fn ->
          {:ok, stdio_pid} = Stdio.start_link(name, base_config())
          send(caller, {:stdio, stdio_pid})
          # Block until killed.
          receive do
            :never -> :ok
          end
        end)

      assert_receive {:stdio, stdio_pid}, 30_000
      stdio_ref = Process.monitor(stdio_pid)

      # Kill the parent. Pre-fix the Stdio's catch-all `:EXIT`
      # handler swallowed the link signal and the process kept
      # running. Post-fix the parent-EXIT clause matches and stops
      # cleanly via `terminate/2`.
      started = System.monotonic_time(:millisecond)
      Process.exit(parent, :kill)

      assert_receive {:DOWN, ^stdio_ref, :process, ^stdio_pid, _reason}, 1_500
      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed < 1_000,
             "expected Stdio to stop < 1000ms after parent death, got #{elapsed}ms"

      # Drain any propagated `{:EXIT, ...}` from the killed parent
      # so it doesn't pollute the next assertion.
      receive do
        {:EXIT, ^parent, _} -> :ok
      after
        100 -> :ok
      end

      # Names registration is now free — a fresh start_link for the
      # same upstream name MUST succeed. Pre-fix: this returns
      # `{:already_started, _}` because the leaked Stdio still
      # owns the registry slot.
      assert {:ok, fresh_pid} = Stdio.start_link(name, base_config())

      ExUnit.Callbacks.on_exit(fn ->
        try do
          GenServer.stop(fresh_pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end)

      assert is_pid(fresh_pid)
      assert Process.alive?(fresh_pid)
    end

    @tag timeout: 30_000
    test "supervisor :shutdown mid-handshake propagates (codex `46b4466` [P2] #3)" do
      # Codex review of `46b4466` flagged that
      # `Stdio.start_link/2`'s post-`GenServer.start_link/3`
      # `receive {:EXIT, _, _} after 0` matched ANY exit signal
      # — including a supervisor's shutdown sent to the caller
      # (the owning Connection) mid-handshake. That EXIT was
      # silently consumed in the start_link wrapper's mailbox,
      # the parent-EXIT handler downstream never saw it, and
      # graceful shutdown stalled until the supervisor's 5s
      # `:kill` timeout escalation.
      #
      # The fix removes the catch-all drain entirely (verified
      # empirically that `:proc_lib.start_link` already
      # internalizes the link signal under trap_exit, so no
      # spurious EXITs survive `start_link/3`).
      #
      # Discriminating signal: drive a real DynamicSupervisor →
      # Connection → Stdio chain. The Stdio handshake is slow
      # (5s `MOCK_INIT_DELAY_MS`). We call `terminate_child/2`
      # while Connection is BLOCKED inside `Stdio.start_link/2`.
      # Post-fix: the supervisor's `:shutdown` lands in Connection's
      # mailbox; once start_link returns, the parent-EXIT clause
      # matches and Connection stops cleanly within the 5s
      # `:shutdown` budget. Pre-fix: the start_link wrapper
      # consumed the EXIT, Connection's own shutdown signal was
      # lost, the supervisor escalated to `:kill` at 5s, and the
      # resulting DOWN reason was `:killed` (not `:shutdown`).
      #
      # We assert: (a) Connection dies within 7s of terminate_child
      # being called (handshake delay 5s + small slack — but well
      # below 5s + 5s = 10s if the kill escalation fired); AND
      # (b) the DOWN reason is the supervisor's `:shutdown`, NOT
      # `:killed`. The reason check is the precise discriminator.
      sup_name = :"sup-mid-shutdown-#{System.unique_integer([:positive])}"

      {:ok, sup} =
        DynamicSupervisor.start_link(name: sup_name, strategy: :one_for_one)

      ExUnit.Callbacks.on_exit(fn ->
        try do
          Process.exit(sup, :shutdown)
        catch
          :exit, _ -> :ok
        end
      end)

      name = unique_name("mid-handshake-shutdown")
      config = base_config(%{"MOCK_INIT_DELAY_MS" => "5000"})

      {:ok, conn_pid} =
        DynamicSupervisor.start_child(
          sup,
          %{
            id: {Connection, name},
            start: {Connection, :start_link, [{name, Stdio, config}]},
            type: :worker,
            restart: :transient,
            shutdown: 5_000
          }
        )

      conn_ref = Process.monitor(conn_pid)

      # Give Connection time to dispatch into `Stdio.start_link/2`
      # and Stdio's init time to reach the slow `wait_for_id`
      # receive on the 5s `initialize` reply. 200ms is well
      # within the 5s init delay window.
      receive do
      after
        300 -> :ok
      end

      assert Process.alive?(conn_pid),
             "Connection should still be running mid-handshake"

      # `terminate_child/2` is synchronous-ish: it sends
      # `:shutdown` then waits up to `child_spec.shutdown` ms
      # before `:kill`. We start a timer here so we can assert
      # the actual wall-clock — pre-fix this would be ~5s
      # (kill escalation), post-fix << 1s once start_link sees
      # the slow init's eventual completion OR the parent-EXIT
      # clause fires once we leave start_link.
      task =
        Task.async(fn ->
          DynamicSupervisor.terminate_child(sup, conn_pid)
        end)

      # The DOWN reason is the precise discriminator. Post-fix
      # the supervisor's `:shutdown` propagates and Connection
      # stops with that reason. Pre-fix the EXIT was consumed
      # by the start_link wrapper, kill escalation fired at 5s,
      # DOWN reason is `:killed`.
      #
      # Allow up to 8s wall-clock — generous enough to let the
      # MockServer's 5s init delay complete naturally on slow
      # CI, but tight enough that a `:killed` escalation (which
      # post-fix should NEVER happen) is still distinguishable.
      assert_receive {:DOWN, ^conn_ref, :process, ^conn_pid, reason}, 8_000

      _ = Task.await(task, 10_000)

      assert reason == :shutdown,
             """
             expected DOWN reason :shutdown (graceful supervisor shutdown), \
             got #{inspect(reason)}. \
             :killed indicates the supervisor's :shutdown timeout fired and \
             escalated to :kill — pre-fix the start_link wrapper consumed \
             the supervisor's :shutdown EXIT signal, so Connection never \
             saw it.
             """

      # Cleanup any leaked Stdio for the same upstream name.
      Stdio.stop(name)
    end
  end

  describe "discard-mode across chunks (codex [P2] #1 regression)" do
    test "oversized line split across chunks fails ONE call, not unrelated pending calls" do
      # Codex review of `fe72ff6` flagged that when an oversized
      # line arrives split across multiple Port chunks, the
      # previous implementation cleared the discard-mode flag at
      # the end of `fail_oldest_pending_too_large/2` and treated
      # the next chunk as a fresh frame — re-tripping the cap on
      # the trailing bytes and failing an UNRELATED pending call.
      #
      # The fix tracks `:discarding_until_newline?` across chunks:
      # once tripped, every subsequent chunk is sliced at the next
      # `\n` BEFORE it touches the buffer, so trailing bytes of
      # the one oversized line cannot fail any other pending call.
      #
      # We drive the streaming-consumption state machine directly
      # via `__test_consume_chunk__/2` (Stdio's test seam) because
      # OS pipe chunking is non-deterministic against a real
      # subprocess. The seam is named `__test_*` precisely so it
      # is impossible to mistake for a public API.

      caller = self()

      # Two pending calls (id=1 oldest, id=2 newer). Both have a
      # `from` that lets us verify which one received the
      # `:response_too_large` reply.
      ref1 = make_ref()
      ref2 = make_ref()

      pending = %{
        1 => %{
          from: {caller, ref1},
          timer: nil,
          max_bytes: 100,
          deadline: 0
        },
        2 => %{
          from: {caller, ref2},
          timer: nil,
          max_bytes: 100,
          deadline: 0
        }
      }

      state =
        Stdio.__test_initial_state__(
          pending: pending,
          max_response_bytes: 100,
          next_id: 3
        )

      # Chunk 1: 200 bytes of an oversized response, no newline.
      # Trips the cap → oldest pending call (id=1) fails with
      # `:response_too_large`. Discard-mode is armed.
      chunk1 = String.duplicate("x", 200)
      state = Stdio.__test_consume_chunk__(state, chunk1)

      assert state.discarding_until_newline? == true,
             "expected discard-mode armed after first oversized chunk"

      # The oldest call (id=1) received the failure reply. id=2 is
      # still pending.
      assert_received {^ref1, {:error, :response_too_large, _}}
      refute_received {^ref2, _}

      assert Map.has_key?(state.pending, 2),
             "id=2 must remain pending after the oversized line failed id=1"

      refute Map.has_key?(state.pending, 1),
             "id=1 must have been removed from pending"

      # Chunk 2: another 200 bytes of the same oversized line, no
      # newline yet. Pre-fix this would have RE-tripped the cap
      # on the freshly-accumulated bytes and failed id=2. Post-fix
      # the discard-mode handler sees no newline, drops the chunk
      # entirely, and id=2 stays pending.
      chunk2 = String.duplicate("y", 200)
      state = Stdio.__test_consume_chunk__(state, chunk2)

      assert state.discarding_until_newline? == true,
             "expected discard-mode still armed (no newline in chunk 2)"

      refute_received {^ref2, _},
                      "id=2 must NOT receive any reply while we discard the oversized line's tail"

      assert Map.has_key?(state.pending, 2)
      assert state.buffer == ""

      # Chunk 3: trailing bytes of the oversized line + newline +
      # the start of a normal-sized response. Discard-mode resolves;
      # the buffer resumes accumulation with whatever followed the
      # newline.
      chunk3 = String.duplicate("z", 50) <> "\n{\"jsonrpc\":\"2.0\",\"id\":2,"
      state = Stdio.__test_consume_chunk__(state, chunk3)

      assert state.discarding_until_newline? == false,
             "discard-mode must clear once we see the terminating newline"

      # The buffer now holds the partial id=2 response (no newline
      # yet). id=2 is still pending; no reply has been delivered.
      refute_received {^ref2, _}
      assert Map.has_key?(state.pending, 2)

      # Chunk 4: the rest of id=2's response + newline. id=2 now
      # gets its real reply (success). Pre-fix none of this would
      # have worked — id=2 would have failed at chunk 2 and the
      # response that finally arrived would be ignored as a late
      # frame.
      chunk4 = "\"result\":{\"ok\":true}}\n"
      _state = Stdio.__test_consume_chunk__(state, chunk4)

      assert_received {^ref2, {:ok, %{"ok" => true}}}
    end

    test "single-chunk oversized line is rejected pre-decode (codex `46b4466` [P2] #1)" do
      # Codex review of `46b4466` flagged that the cap-enforcement
      # only fired on the "split across chunks" path — when no
      # newline existed in the buffer. A chunk carrying
      # `<oversized line>\n` extracted the line and decoded it
      # directly, bypassing pre-decode size enforcement entirely.
      # That's the common framing for upstreams that flush a
      # complete line at once (which most do).
      #
      # The fix performs the cap check on the framed line BEFORE
      # `Jason.decode!` runs. We can't directly observe "Jason.decode
      # was not called" without a stub, so the discriminating
      # signal is the byte_size in the error detail: pre-decode
      # rejection includes the line's `byte_size` AND the literal
      # "(pre-decode)" tag, while a post-decode rejection (the
      # path we removed) would have included an `encoded_size`
      # value plus the "exceeds max_response_bytes" wording from
      # the older `handle_response/3` clause. Either way, pre-fix
      # the cap check is silently skipped and the call would
      # complete successfully.
      caller = self()
      ref = make_ref()

      pending = %{
        1 => %{
          from: {caller, ref},
          timer: nil,
          max_bytes: 100,
          deadline: 0
        }
      }

      state =
        Stdio.__test_initial_state__(
          pending: pending,
          max_response_bytes: 100,
          next_id: 2
        )

      # Single chunk: a 200-byte JSON line + terminating newline.
      # Construct as a syntactically valid JSON-RPC response so
      # that a hypothetical post-decode-only enforcement path
      # would have to choose between failing on size or returning
      # the value as `{:ok, ...}`. The cap is 100; the line is
      # ~200 bytes — well over.
      payload = String.duplicate("x", 150)
      line = ~s({"jsonrpc":"2.0","id":1,"result":"#{payload}"})
      assert byte_size(line) > 100, "line must exceed cap to exercise the regression"
      chunk = line <> "\n"

      _state = Stdio.__test_consume_chunk__(state, chunk)

      # Discriminator 1: id=1 receives :response_too_large.
      assert_received {^ref, {:error, :response_too_large, detail}}

      # Discriminator 2: the error detail names the line size and
      # carries the "(pre-decode)" tag — this string is emitted
      # ONLY by the new pre-decode path. Pre-fix the line was
      # handed to `Jason.decode/1` and the post-decode path's
      # wording was different. If the cap were silently skipped
      # entirely (the actual codex finding), the test would never
      # `receive` any reply for id=1 and `assert_received` would
      # fail.
      assert detail =~ "(pre-decode)",
             "expected pre-decode rejection tag in detail, got: #{detail}"

      assert detail =~ Integer.to_string(byte_size(line)),
             "expected line byte_size in detail, got: #{detail}"
    end
  end

  describe "relative command resolved against :cd (codex [P2] #1 regression)" do
    @tag timeout: 30_000
    test "command './bin/server' with :cd lands at <cd>/bin/server, not PtcRunner's CWD" do
      # Codex review of `0f6c1cd` flagged that a relative path
      # `command` was `File.regular?`-checked against PtcRunner's
      # CWD before `Port.open` applied `:cd`. Project-local
      # binaries (`./bin/server` plus `cd: /opt/upstream`) failed
      # spawn even though the file existed at the configured
      # `:cd`-relative location.
      #
      # Discriminating signal: drop a real executable at
      # `<tmpdir>/bin/server`, set `cd: <tmpdir>` and
      # `command: "./bin/server"`, and verify `Stdio.start_link/2`
      # returns `{:ok, _}` with a successful handshake. Pre-fix
      # `locate_executable/1` saw `./bin/server` not-regular?
      # against PtcRunner's mcp_server CWD (where no such path
      # exists) and returned `{:error, "command not found"}`,
      # surfacing as `{:error, {:upstream_unavailable, _}}` from
      # `start_link/2`.
      #
      # The executable is a tiny shell wrapper that writes a probe
      # file (proving it was actually invoked from the right path)
      # and then `exec`s the real MockServer. Without the wrapper
      # we couldn't both prove the resolve worked AND complete a
      # real MCP handshake to keep `start_link/2` honest.
      tmp_dir =
        Path.join(System.tmp_dir!(), "phase1b-cdrel-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(tmp_dir, "bin"))
      probe_path = Path.join(tmp_dir, "probe.txt")

      wrapper = Path.join([tmp_dir, "bin", "server"])
      project_dir = File.cwd!()
      mock_abs = Path.join(project_dir, @mock_path)

      # The wrapper records `$0` (proves Stdio resolved the
      # configured `./bin/server` against `:cd`) then `cd`s into
      # the Mix project root so `mix run` can find `mix.exs`. Note
      # that the wrapper's runtime CWD when launched is the
      # `:cd`-supplied `tmp_dir`, NOT the project root — so we
      # must `cd` ourselves before `exec mix`.
      File.write!(wrapper, """
      #!/bin/sh
      printf '%s' "$0" > #{probe_path}
      cd #{project_dir}
      exec mix run --no-start --no-compile #{mock_abs}
      """)

      File.chmod!(wrapper, 0o755)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      name = unique_name("cd-relative")

      config = %{
        command: "./bin/server",
        args: [],
        env: %{},
        cd: tmp_dir,
        handshake_timeout_ms: 15_000
      }

      # Pre-fix this errors: `Stdio.start_link/2` returns
      # `{:error, {:upstream_unavailable, "command not found: ./bin/server"}}`.
      assert {:ok, pid} = Stdio.start_link(name, config)

      ExUnit.Callbacks.on_exit(fn ->
        try do
          Stdio.stop(name)
        catch
          :exit, _ -> :ok
        end
      end)

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Round-trip a `tools/call` to confirm the wrapper actually
      # `exec`d the real MockServer and the handshake completed.
      assert {:ok, _} = Stdio.list_tools(name)

      # The wrapper wrote its $0 to probe_path. Discriminator: the
      # probe contains the cd-relative resolution, NOT a CWD-rooted
      # path. We assert the probe path resolves under tmp_dir and
      # the basename matches.
      assert File.exists?(probe_path),
             "wrapper script never ran — Port did not spawn the cd-relative command"

      probe = File.read!(probe_path)

      # `$0` in the wrapper is whatever the kernel was asked to
      # exec — i.e., the path Stdio resolved. Pre-fix we'd never
      # reach this assertion (start_link errored). Post-fix the
      # probe contains a path whose basename is `server` and whose
      # directory is `<tmp_dir>/bin` (or a symlink-equivalent).
      assert Path.basename(probe) == "server"

      probe_dir = probe |> Path.dirname() |> Path.expand()
      bin_dir = Path.expand(Path.join(tmp_dir, "bin"))

      assert probe_dir == bin_dir,
             "expected wrapper to be invoked from #{bin_dir}, got #{probe_dir}"
    end
  end
end
