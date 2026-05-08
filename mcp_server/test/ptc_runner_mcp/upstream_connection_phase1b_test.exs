defmodule PtcRunnerMcp.UpstreamConnectionPhase1bTest do
  @moduledoc """
  Phase 1b unit tests for `PtcRunnerMcp.Upstream.Connection`.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §4.4 — the Connection
  worker owns per-name `ensure_started/1` serialization, monitor +
  cached_tools state, and the recovery-backoff window.

  These tests exercise the Connection in isolation (no routing
  Registry, no AggregatorTools) so failures are diagnosable at the
  layer that introduced them.

  Covers (per §13.3 + the phase-1b execution-order brief):

    * Mailbox-as-per-name-lock: concurrent `ensure_started/1` for
      one Connection observes exactly ONE impl `start_link/2` attempt.
    * Crash invalidation: killing the impl pid transitions the
      Connection back to `:not_started` and clears `cached_tools`.
    * Recovery backoff: a crash arms the backoff window; subsequent
      `ensure_started/1` during the window returns
      `{:error, :upstream_unavailable, _, _}` without re-attempting.
      Backoff is fast-forwardable via `:backoff_initial_ms` in
      config (no wall-clock sleep in tests).
    * Init failure does NOT arm the backoff window — within-program
      suppression lives in `AggregatorTools`'s per-program ETS cache;
      across-program retries must be allowed (§4.3 first bullet).
  """
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Upstream.{Connection, Fake}

  defp tools_config(tools) do
    %{
      tools:
        Map.new(tools, fn {n, fun} ->
          {n, {%{name: n, input_schema: %{}}, fun}}
        end)
    }
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp start_connection!(name, impl, config) do
    {:ok, pid} = Connection.start_link({name, impl, config})
    on_exit_stop(pid)
    pid
  end

  defp on_exit_stop(pid) do
    ExUnit.Callbacks.on_exit(fn ->
      try do
        Connection.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  describe "ensure_started/1 mailbox-as-per-name-lock (§4.4)" do
    test "concurrent callers observe exactly one impl start_link/2" do
      # Counter incremented inside the Fake's `init/1` per
      # `init_attempts`. With the Connection mailbox as the
      # per-name lock, 8 concurrent `ensure_started/1` callers
      # MUST see exactly 1 spawn attempt — the leader's; the rest
      # observe the cached `:started` state and return immediately.
      attempts = :atomics.new(1, signed: false)
      name = unique_name("lock")

      pid =
        start_connection!(
          name,
          Fake,
          %{
            init_attempts: attempts,
            init_delay_ms: 50,
            tools: %{
              "ping" => {%{name: "ping", input_schema: %{}}, fn _, _ -> {:ok, "pong"} end}
            }
          }
        )

      tasks =
        for _ <- 1..8 do
          Task.async(fn -> Connection.ensure_started(pid) end)
        end

      results = Task.await_many(tasks, 5_000)

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)

      assert :atomics.get(attempts, 1) == 1,
             "expected exactly 1 start_link attempt, got #{:atomics.get(attempts, 1)}"

      assert Connection.started?(pid)
    end
  end

  describe "crash invalidation (§4.3 third bullet)" do
    test "kill of impl pid transitions Connection back to :not_started" do
      name = unique_name("crash")

      pid =
        start_connection!(
          name,
          Fake,
          tools_config(%{"echo" => fn args, _ -> {:ok, args} end})
        )

      assert {:ok, _} = Connection.ensure_started(pid)
      assert Connection.started?(pid)
      assert is_list(Connection.cached_tools(pid))

      snap = Connection.snapshot(pid)
      assert snap.status == :started
      fake_pid = snap.pid

      # Synchronously wait for the Fake's death AND the Connection's
      # `:DOWN` handler to run. The handler is a `handle_info` —
      # any subsequent `GenServer.call` to the Connection (e.g.
      # `started?`) is FIFO-after the handle_info, so by the time
      # `started?` returns the invalidation has been applied.
      ref = Process.monitor(fake_pid)
      Process.exit(fake_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^fake_pid, :killed}, 1_000

      refute Connection.started?(pid)
      assert Connection.cached_tools(pid) == nil
    end

    test "clean Fake.stop/1 (normal exit) does NOT arm the backoff window" do
      # The recovery-backoff window applies to `:DOWN` from a CRASH
      # (abnormal exit), not from a clean shutdown. Without this
      # distinction, `Fake.stop/1` (which exits `:normal`) would
      # falsely lock out the next `ensure_started/1`.
      name = unique_name("clean")

      pid =
        start_connection!(
          name,
          Fake,
          tools_config(%{"echo" => fn args, _ -> {:ok, args} end})
        )

      assert {:ok, _} = Connection.ensure_started(pid)

      snap = Connection.snapshot(pid)
      fake_pid = snap.pid

      ref = Process.monitor(fake_pid)
      :ok = Fake.stop(name)
      assert_receive {:DOWN, ^ref, :process, ^fake_pid, _}, 1_000
      # Sync mailbox so the Connection has processed the :DOWN.
      _ = Connection.snapshot(pid)

      refute Connection.started?(pid)
      # Re-attempt MUST succeed — clean shutdown does not arm backoff.
      assert {:ok, _} = Connection.ensure_started(pid)
      assert Connection.started?(pid)
    end
  end

  describe "recovery backoff after a crash" do
    test "abnormal exit arms backoff; ensure_started during window returns :upstream_unavailable" do
      # `:backoff_initial_ms: 200` means a healthy → crashed → wait
      # transition rejects re-spawn for ~200ms. The test asserts the
      # rejection deterministically by checking IMMEDIATELY after
      # the `:DOWN`, well within the window. After the window, a
      # fresh attempt is allowed — exercised by the test below.
      name = unique_name("backoff")

      pid =
        start_connection!(
          name,
          Fake,
          %{
            backoff_initial_ms: 200,
            tools: %{
              "echo" => {%{name: "echo", input_schema: %{}}, fn args, _ -> {:ok, args} end}
            }
          }
        )

      assert {:ok, _} = Connection.ensure_started(pid)
      fake_pid = Connection.snapshot(pid).pid

      # Crash the impl; the Connection's `:DOWN` handler arms the
      # backoff window. We synchronize via the test process's
      # monitor on the Fake plus a snapshot call (FIFO after the
      # `handle_info`) so the rejection assertion is deterministic.
      ref = Process.monitor(fake_pid)
      Process.exit(fake_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^fake_pid, :killed}, 1_000
      _ = Connection.snapshot(pid)

      assert {:error, :upstream_unavailable, "in recovery", %{duration_ms: 0}} =
               Connection.ensure_started(pid)
    end

    test "after the backoff window expires, ensure_started attempts a fresh spawn" do
      # `:backoff_initial_ms: 5` lets the test wait past the window
      # without wall-clock flakiness. `assert_receive` on a refresh
      # `:DOWN` synchronizes the crash; a 50ms `assert_receive` on
      # an unrelated message advances time deterministically.
      name = unique_name("backoff-recover")

      pid =
        start_connection!(
          name,
          Fake,
          %{
            backoff_initial_ms: 5,
            tools: %{
              "echo" => {%{name: "echo", input_schema: %{}}, fn args, _ -> {:ok, args} end}
            }
          }
        )

      assert {:ok, _} = Connection.ensure_started(pid)
      fake_pid = Connection.snapshot(pid).pid

      ref = Process.monitor(fake_pid)
      Process.exit(fake_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^fake_pid, :killed}, 1_000
      _ = Connection.snapshot(pid)

      # Wait deterministically for the 5ms window to expire.
      # `:timer.sleep` is forbidden by CLAUDE.md; use a bounded
      # `receive after` instead.
      receive do
      after
        20 -> :ok
      end

      assert {:ok, _} = Connection.ensure_started(pid)
      assert Connection.started?(pid)
    end

    test "init-failure does NOT arm the backoff window (§4.3 first bullet)" do
      # An init failure is NOT a crash — it's a "this program tried
      # and failed." Within-program suppression is owned by
      # `AggregatorTools`'s per-program failure cache; across-program
      # retries MUST proceed unobstructed. If init-failure armed the
      # Connection's backoff window, two sequential programs would
      # see the second one fail with "in recovery" instead of
      # re-attempting.
      name = unique_name("init-fail")

      pid =
        start_connection!(
          name,
          Fake,
          %{
            backoff_initial_ms: 5_000,
            init_result: {:error, :upstream_unavailable, "boom"}
          }
        )

      assert {:error, :upstream_unavailable, "boom", _} = Connection.ensure_started(pid)

      # Second call MUST get the same fresh error, NOT "in recovery".
      assert {:error, :upstream_unavailable, "boom", _} = Connection.ensure_started(pid)
    end
  end

  describe "snapshot/1" do
    test "before ensure_started: status :not_started, cached_tools nil" do
      name = unique_name("snap-cold")
      pid = start_connection!(name, Fake, tools_config(%{}))

      snap = Connection.snapshot(pid)
      assert snap.name == name
      assert snap.impl == Fake
      assert snap.status == :not_started
      assert snap.cached_tools == nil
      assert snap.pid == nil
    end

    test "after successful ensure_started: status :started, cached_tools populated" do
      name = unique_name("snap-warm")

      pid =
        start_connection!(
          name,
          Fake,
          tools_config(%{"x" => fn _, _ -> {:ok, 1} end})
        )

      assert {:ok, _} = Connection.ensure_started(pid)
      snap = Connection.snapshot(pid)
      assert snap.status == :started
      assert is_list(snap.cached_tools)
      assert is_pid(snap.pid)
    end
  end

  describe "owner-down auto-stop" do
    test "Connection stops itself when its `owner` pid dies" do
      # Simulates the `Process.exit(registry, :kill)` path used in
      # test cleanup: the routing Registry passes `self()` as the
      # Connection's owner; when the Registry dies, the Connection
      # MUST stop, releasing its impl from the global
      # `Upstream.Fake.Names`.
      name = unique_name("owner-down")

      owner = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, pid} =
        Connection.start_link(
          {name, Fake, tools_config(%{"x" => fn _, _ -> {:ok, 1} end}), owner}
        )

      conn_ref = Process.monitor(pid)

      # Kill the owner; the Connection's monitor on owner fires,
      # the Connection stops cleanly (and its `terminate/2` calls
      # `Fake.stop/1` if started).
      Process.exit(owner, :kill)

      assert_receive {:DOWN, ^conn_ref, :process, ^pid, :normal}, 1_000
    end
  end

  describe "supervisor shutdown via terminate_child (codex [P2] regression)" do
    test "DynamicSupervisor.terminate_child/2 runs terminate/2 → Fake.stop/1 within shutdown budget" do
      # Codex review of `3c2754d` flagged that the catch-all
      # `:EXIT` handler swallowed the supervisor's shutdown EXIT
      # signal, so `terminate/2` never ran `impl.stop/1` until the
      # `:shutdown: 5_000` timeout escalated to `:kill`. The fix
      # tracks the parent pid in init/1 and stops on parent EXIT
      # cleanly.
      #
      # Discriminating signal: the Fake's GenServer pid dies via
      # `Fake.stop/1` (initiated by `Connection.terminate/2`) BEFORE
      # the supervisor's 5 s shutdown timeout. We observe this via
      # a monitor on the Fake pid + a wall-clock bound. Pre-fix:
      # the Fake survives until `:kill` fires at the 5 s mark, so
      # the assertion's 1 s timeout would expire with the Fake
      # still alive.
      sup_name = :"sup-shutdown-#{System.unique_integer([:positive])}"

      {:ok, sup} =
        DynamicSupervisor.start_link(name: sup_name, strategy: :one_for_one)

      on_exit(fn ->
        try do
          Process.exit(sup, :shutdown)
        catch
          _, _ -> :ok
        end
      end)

      name = unique_name("sup-shutdown")

      {:ok, conn_pid} =
        DynamicSupervisor.start_child(
          sup,
          {Connection, {name, Fake, tools_config(%{"x" => fn _, _ -> {:ok, 1} end})}}
        )

      assert {:ok, _} = Connection.ensure_started(conn_pid)
      fake_pid = Connection.snapshot(conn_pid).pid
      assert is_pid(fake_pid)

      fake_ref = Process.monitor(fake_pid)
      conn_ref = Process.monitor(conn_pid)

      started = System.monotonic_time(:millisecond)
      :ok = DynamicSupervisor.terminate_child(sup, conn_pid)

      # Connection terminated cleanly via terminate/2 → Fake.stop/1.
      # Both pids die well within the 5 s supervisor shutdown
      # budget; pre-fix the Fake would still be alive at this point
      # (terminate/2 never ran), and only the supervisor's :kill
      # at t=5s would take it down.
      assert_receive {:DOWN, ^fake_ref, :process, ^fake_pid, _}, 1_500
      assert_receive {:DOWN, ^conn_ref, :process, ^conn_pid, _}, 500

      elapsed = System.monotonic_time(:millisecond) - started

      # 1 s ceiling. Pre-fix: Fake survives until ~5 s; this
      # assertion fires deterministically.
      assert elapsed < 1_000,
             "expected clean shutdown < 1000 ms, got #{elapsed} ms (likely supervisor :kill escalation)"
    end
  end

  describe "via-registration survives DynamicSupervisor restart (codex [P2] #2 regression)" do
    test "Registry routes to the post-restart Connection pid, not the dead pre-restart pid" do
      # Codex review of `46b4466` flagged that Registry's
      # `connection_for/2` cached the Connection pid set at
      # bootstrap and never refreshed. Connection is
      # `restart: :transient`, so an abnormal exit gives a NEW
      # pid via DynamicSupervisor — but every routed call
      # (`ensure_started`, `cached_tools`, snapshot) after
      # restart hit the dead pre-restart pid and exited `:noproc`.
      #
      # The fix names Connections under
      # `{:via, Registry, {Connection.Names, {routing_id, name}}}`.
      # `Connection.whereis(routing_id, name)` always returns the
      # live pid, INCLUDING after a supervisor restart.
      #
      # Discriminating signal: ensure_started against the
      # routing Registry, kill the Connection's pid, wait for
      # DynamicSupervisor to restart it, then ensure_started
      # AGAIN through the routing Registry. Pre-fix the second
      # call exits `:noproc` because Registry cached the dead
      # pid. Post-fix it succeeds AND the new pid is different
      # from the pre-restart pid.

      # We need a real DynamicSupervisor to drive restart
      # behavior. The test_helper-provided one already exists
      # (PtcRunnerMcp.Upstream.DynamicSupervisor). Each test
      # uses a unique upstream name so via-key collisions are
      # impossible.
      alias PtcRunnerMcp.Upstream.Registry, as: UpstreamRegistry

      reg_name = :"reg-restart-#{System.unique_integer([:positive])}"
      name = unique_name("restart")

      entry = %{
        name: name,
        impl: Fake,
        config: tools_config(%{"x" => fn _, _ -> {:ok, "ok"} end})
      }

      {:ok, reg} = UpstreamRegistry.start_link(name: reg_name, upstreams: [entry])

      ExUnit.Callbacks.on_exit(fn ->
        try do
          GenServer.stop(reg, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end)

      # Pre-restart: route a successful call.
      assert {:ok, _} = UpstreamRegistry.ensure_started(name, reg_name)
      pre_pid = UpstreamRegistry.connection_for(name, reg_name)
      assert is_pid(pre_pid)

      pre_ref = Process.monitor(pre_pid)

      # Kill the Connection abnormally. DynamicSupervisor
      # (`:transient`) sees `:killed` (abnormal) and restarts.
      Process.exit(pre_pid, :kill)
      assert_receive {:DOWN, ^pre_ref, :process, ^pre_pid, :killed}, 1_000

      # Wait for the supervisor to install the restarted Connection
      # under the SAME via key. We poll `Connection.whereis/2`
      # via a bounded `receive after` loop (no `Process.sleep`).
      post_pid = wait_for_restart(reg, name, pre_pid, 2_000)
      assert is_pid(post_pid)
      assert post_pid != pre_pid

      # Pre-fix: this call exits `:noproc` because Registry's
      # `connection_for/2` returned the cached `pre_pid`.
      # Post-fix: Registry resolves through the via registry and
      # gets the live `post_pid`.
      assert {:ok, _} = UpstreamRegistry.ensure_started(name, reg_name)
      assert UpstreamRegistry.connection_for(name, reg_name) == post_pid
    end

    defp wait_for_restart(reg, name, dead_pid, timeout_ms) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      do_wait_for_restart(reg, name, dead_pid, deadline)
    end

    defp do_wait_for_restart(reg, name, dead_pid, deadline) do
      # `connection_for/2` on the routing Registry — we want THE
      # path that production callers exercise.
      pid = PtcRunnerMcp.Upstream.Registry.connection_for(name, reg)

      cond do
        is_pid(pid) and pid != dead_pid and Process.alive?(pid) ->
          pid

        System.monotonic_time(:millisecond) >= deadline ->
          flunk("DynamicSupervisor did not restart Connection within timeout")

        true ->
          receive do
          after
            10 -> do_wait_for_restart(reg, name, dead_pid, deadline)
          end
      end
    end
  end
end
