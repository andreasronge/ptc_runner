defmodule PtcRunnerMcp.UpstreamSupervisorPhase21Test do
  @moduledoc """
  Phase 2.1 regression test for `Upstream.Supervisor`'s cascade
  behavior when the inner `DynamicSupervisor` exhausts its restart
  intensity.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §12.4.1 finding #1, §4.4.

  ## Bug

  Pre-fix, `Upstream.Supervisor.init/1` used `strategy: :one_for_one`.
  When the inner `DynamicSupervisor` exhausted its own
  `max_restarts` budget (e.g. a Connection child crashing in a tight
  loop), only the DynamicSupervisor was restarted by the outer
  supervisor. `Upstream.Registry` stayed alive with its stale state:
  its `init/1`-time bootstrap of Connection children had already run
  against the OLD DynamicSupervisor pid, and was never replayed
  against the new one. Result: `connection_for/2` for any configured
  upstream returned `nil` after the cascade — the aggregator-mode
  service was effectively unusable until restart.

  ## Fix

  `:rest_for_one` strategy with the DynamicSupervisor listed BEFORE
  Registry. When DynamicSupervisor restarts, Registry restarts after
  it and runs its `init/1` bootstrap clean against the new
  DynamicSupervisor pid.

  ## Discriminating signal

  Build a supervisor tree with the SAME shape as
  `Upstream.Supervisor.init/1` (DynamicSupervisor → Registry, with
  upstreams configured), force enough Connection crashes to exhaust
  the DynamicSupervisor's `max_restarts` budget, then assert:

    * The DynamicSupervisor pid changed (restarted).
    * The Registry pid changed too (cascaded restart, the
      discriminator vs the pre-fix `:one_for_one` shape).
    * Configured upstreams are bootstrapped on the new Registry —
      `connection_for/2` returns a fresh, live pid that lives under
      the NEW DynamicSupervisor.

  Also asserts the production `Upstream.Supervisor.init/1` uses
  `:rest_for_one` so the production tree gets the same fix.
  """
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Upstream.Fake
  alias PtcRunnerMcp.Upstream.Registry, as: UpstreamRegistry

  defp unique_atom(prefix), do: :"#{prefix}-#{System.unique_integer([:positive])}"

  # Spawns a copy of the production supervisor tree shape with
  # custom names so it can run alongside the global test fixtures.
  # Uses VERY low `max_restarts` on the DynamicSupervisor so the
  # cascade fires after just two crashes — keeps the test fast and
  # deterministic.
  defp start_isolated_tree!(upstream_name) do
    sup_name = unique_atom("phase21-up-sup")
    dynsup_name = unique_atom("phase21-up-dynsup")
    reg_name = unique_atom("phase21-up-reg")

    upstreams = [
      %{
        name: upstream_name,
        impl: Fake,
        # `:owner` defaults via Registry; Fake config can be empty.
        config: %{}
      }
    ]

    # Mirror the production supervisor's strategy by reading it
    # from `Upstream.Supervisor.init/1`. If production reverts to
    # `:one_for_one`, this isolated tree inherits the same wrong
    # shape and the runtime cascade assertion below FAILS. The
    # discriminator is "production strategy reaches this test path",
    # not "test hardcodes :rest_for_one and always passes".
    {:ok, {prod_flags, _}} = PtcRunnerMcp.Upstream.Supervisor.init(upstreams: [])
    prod_strategy = prod_flags.strategy

    children = [
      {DynamicSupervisor,
       name: dynsup_name, strategy: :one_for_one, max_restarts: 2, max_seconds: 60},
      {UpstreamRegistry, name: reg_name, connection_supervisor: dynsup_name, upstreams: upstreams}
    ]

    {:ok, sup_pid} =
      Elixir.Supervisor.start_link(children,
        strategy: prod_strategy,
        name: sup_name,
        max_restarts: 5,
        max_seconds: 60
      )

    on_exit(fn ->
      try do
        Process.exit(sup_pid, :shutdown)
      catch
        :exit, _ -> :ok
      end
    end)

    %{
      sup: sup_pid,
      sup_name: sup_name,
      dynsup_name: dynsup_name,
      reg_name: reg_name
    }
  end

  describe "DynamicSupervisor restart-intensity cascade (codex #1)" do
    test "production Upstream.Supervisor uses :rest_for_one with DynSup before Registry" do
      # Structural assertion against the actual production module:
      # if the strategy is `:one_for_one` or the child order is
      # reversed, the runtime cascade test below could pass for a
      # locally-isolated tree while production is still broken.
      # Pin the production layout here.
      {:ok, {flags, children}} =
        PtcRunnerMcp.Upstream.Supervisor.init(upstreams: [])

      assert flags.strategy == :rest_for_one,
             "expected :rest_for_one strategy, got #{inspect(flags.strategy)}"

      ids = Enum.map(children, & &1.id)

      # The child spec's `id` is the `:name` option (the registered
      # name); the module-level child_spec/1 default is the module
      # itself when no `:name` is given.
      dynsup_idx = Enum.find_index(ids, &(&1 == PtcRunnerMcp.Upstream.DynamicSupervisor))
      reg_idx = Enum.find_index(ids, &(&1 == PtcRunnerMcp.Upstream.Registry))

      assert is_integer(dynsup_idx)
      assert is_integer(reg_idx)

      assert dynsup_idx < reg_idx,
             "DynamicSupervisor must be listed BEFORE Registry under :rest_for_one " <>
               "so a DynSup restart cascades to Registry. Got order: #{inspect(ids)}"
    end

    test "DynSup restart-intensity exhaustion cascades to Registry via :rest_for_one" do
      upstream = "alpha-#{System.unique_integer([:positive])}"
      %{dynsup_name: dynsup_name, reg_name: reg_name} = start_isolated_tree!(upstream)

      # Snapshot pre-cascade pids.
      dynsup_pid_before = Process.whereis(dynsup_name)
      reg_pid_before = Process.whereis(reg_name)
      conn_pid_before = UpstreamRegistry.connection_for(upstream, reg_name)

      assert is_pid(dynsup_pid_before)
      assert is_pid(reg_pid_before)
      assert is_pid(conn_pid_before)
      assert Process.alive?(conn_pid_before)

      dynsup_ref = Process.monitor(dynsup_pid_before)
      reg_ref = Process.monitor(reg_pid_before)

      # Crash the Connection enough times to exhaust the
      # DynamicSupervisor's `max_restarts: 2 / max_seconds: 60`
      # budget. Three abnormal exits in <60s trips it: DynSup
      # exits with `:shutdown`, then the outer supervisor
      # restarts it under :rest_for_one, which also restarts the
      # Registry.
      #
      # Iteration is bounded by a wall-clock deadline (well under
      # the DynSup's 60s `max_seconds` window) and counts only
      # *real* abnormal kills issued. See `crash_until_dynsup_dies!`
      # for the race-tolerance details (already-dead-pid lookups,
      # transient `:noproc` from the Registry during the cascade).
      crash_until_dynsup_dies!(reg_name, upstream, dynsup_ref, 5_000)

      # 1. DynamicSupervisor restarted (pid changed).
      assert_receive {:DOWN, ^dynsup_ref, :process, ^dynsup_pid_before, _}, 5_000

      # 2. Registry ALSO restarted (the :rest_for_one
      #    discriminator). Pre-fix this DOWN never arrives — the
      #    Registry survives a DynSup restart under :one_for_one
      #    because the outer strategy is named the wrong way.
      assert_receive {:DOWN, ^reg_ref, :process, ^reg_pid_before, _}, 5_000

      # Wait for the supervisor to re-spawn both children. Use a
      # bounded poll on the registered names — no Process.sleep.
      dynsup_pid_after = await_registered!(dynsup_name, dynsup_pid_before, 5_000)
      reg_pid_after = await_registered!(reg_name, reg_pid_before, 5_000)

      assert dynsup_pid_after != dynsup_pid_before
      assert reg_pid_after != reg_pid_before

      # 3-4. The new Registry's init/1 re-bootstrapped the
      #      configured upstream — verify atomically that:
      #        a) Registry resolves the upstream to a pid,
      #        b) that pid is alive,
      #        c) that pid is a child of the new DynamicSupervisor,
      #        d) that pid differs from the pre-cascade pid (the
      #           cascade actually happened, not a stale reference).
      #      Polled together because under parallel-test load a
      #      Connection can die-and-be-respawned by the new DynSup
      #      between any two single-step checks, leaving stale
      #      references that flake `Process.alive?/1` or
      #      `which_children/1`.
      _conn_pid_after =
        await_consistent_connection!(
          upstream,
          reg_name,
          dynsup_pid_after,
          conn_pid_before,
          5_000
        )

      # The helper raises if any of (a)–(d) fails to hold within the
      # timeout, so by here we know the cascade re-bootstrapped a
      # fresh, alive Connection that is a child of the new DynSup.
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  # Repeatedly kill the configured upstream's Connection until the
  # DynamicSupervisor exhausts its restart intensity and exits, or
  # until the wall-clock deadline `timeout_ms` elapses. Each
  # iteration waits for the per-Connection :DOWN before issuing the
  # next kill (no Process.sleep). The DynSup's :DOWN, when it
  # arrives, is also received here — we re-send it to ourselves so
  # the main test body can match on its monitor ref via
  # assert_receive.
  #
  # ## Race tolerance
  #
  # The discriminating signal is "the DynSup's restart budget gets
  # tripped, the cascade fires, the test body's `assert_receive
  # {:DOWN, dynsup_ref, ...}` then matches". For that we need
  # exactly 3 *real* abnormal exits of the Connection child
  # observed by the DynSup. Two races used to consume iterations
  # without producing real kills:
  #
  #   1. **Already-dead pid lookup.** `Connection.whereis` resolves
  #      via a `:via` Registry whose unregister is event-driven on
  #      the Connection's `:DOWN`. Between the Connection process
  #      dying and the `:via` Registry observing the DOWN, the
  #      lookup returns the *dead* pid. `Process.exit(dead, :kill)`
  #      is a no-op and `Process.monitor(dead)` synthesizes a
  #      `:noproc` `:DOWN` immediately. With the previous
  #      iteration-counter design this looked like a successful
  #      kill, decremented the budget, and the loop ran out before
  #      hitting 3 *real* kills.
  #
  #   2. **`:noproc` raise from `connection_for`.** Once the cascade
  #      fires, the named Registry process is gone for ~ms. A
  #      `GenServer.call/3` to that name raises `:noproc`. The
  #      previous design did not catch it, so the test crashed
  #      with an `(EXIT) no process` instead of completing the
  #      cascade-discrimination assertions.
  #
  # The current loop:
  #
  #   * uses a wall-clock `deadline_ms` (default 5s — well inside
  #     the DynSup's 60s `max_seconds` window),
  #   * catches `:noproc` from `connection_for` (treats it like
  #     a transient nil),
  #   * skips lookups that return an already-dead pid without
  #     consuming budget (the DOWN `:noproc` reason marks them
  #     as not-a-real-kill),
  #   * counts only abnormal `:killed` exits as real kills,
  #   * stops as soon as the DynSup `:DOWN` arrives mid-loop.
  defp crash_until_dynsup_dies!(reg_name, upstream, dynsup_ref, timeout_ms) do
    deadline_mono = System.monotonic_time(:millisecond) + timeout_ms
    do_crash_until_dynsup_dies(reg_name, upstream, dynsup_ref, deadline_mono, 0)
  end

  defp do_crash_until_dynsup_dies(reg_name, upstream, dynsup_ref, deadline_mono, real_kills) do
    if System.monotonic_time(:millisecond) >= deadline_mono do
      flunk(
        "DynamicSupervisor restart-intensity not exhausted within deadline " <>
          "(real_kills=#{real_kills})"
      )
    else
      lookup =
        try do
          {:ok, UpstreamRegistry.connection_for(upstream, reg_name)}
        catch
          # Registry is restarting under the cascade — its named
          # process is momentarily `:noproc`. Treat as a transient
          # "no connection" and retry without consuming budget.
          :exit, {:noproc, _} -> {:ok, nil}
          :exit, {:normal, _} -> {:ok, nil}
          :exit, {:shutdown, _} -> {:ok, nil}
        end

      case lookup do
        {:ok, nil} ->
          # No live Connection right now — either between restarts
          # or the cascade is in progress. Wait briefly for
          # re-register or for the DynSup DOWN.
          receive do
            {:DOWN, ^dynsup_ref, :process, _, _} = msg ->
              send(self(), msg)
              :ok
          after
            25 ->
              do_crash_until_dynsup_dies(
                reg_name,
                upstream,
                dynsup_ref,
                deadline_mono,
                real_kills
              )
          end

        {:ok, pid} when is_pid(pid) ->
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, :noproc} ->
              # The lookup returned a dead pid (the `:via` Registry
              # had not yet processed the previous Connection's
              # exit). No real abnormal exit was observed by the
              # DynSup — do NOT count this toward `real_kills`.
              do_crash_until_dynsup_dies(
                reg_name,
                upstream,
                dynsup_ref,
                deadline_mono,
                real_kills
              )

            {:DOWN, ^ref, :process, ^pid, _reason} ->
              # Real abnormal exit observed by the DynSup.
              do_crash_until_dynsup_dies(
                reg_name,
                upstream,
                dynsup_ref,
                deadline_mono,
                real_kills + 1
              )

            {:DOWN, ^dynsup_ref, :process, _, _} = msg ->
              # DynSup died first (or simultaneously) — re-queue
              # for the main test body and stop crashing.
              send(self(), msg)
              :ok
          after
            2_000 -> flunk("Connection #{inspect(pid)} did not die after :kill")
          end
      end
    end
  end

  defp await_registered!(name, old_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_registered(name, old_pid, deadline)
  end

  defp do_await_registered(name, old_pid, deadline) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("process #{inspect(name)} was not re-registered with a fresh pid")
        else
          receive do
          after
            10 -> :ok
          end

          do_await_registered(name, old_pid, deadline)
        end
    end
  end

  # Atomically poll for a Connection that simultaneously satisfies
  # all four conditions:
  #   (a) Registry resolves the upstream to a pid,
  #   (b) that pid is alive,
  #   (c) that pid is a child of the given new DynSup,
  #   (d) that pid != the pre-cascade pid (i.e. the cascade
  #       actually re-bootstrapped, not a stale reference).
  #
  # Single-shot lookups race under load: a Connection can crash and
  # be respawned by the new DynSup between any two checks. Polling
  # the predicate as one block — and only returning when all four
  # hold for the same pid simultaneously — is race-free.
  defp await_consistent_connection!(upstream, reg_name, dynsup_pid, conn_pid_before, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_consistent_connection(upstream, reg_name, dynsup_pid, conn_pid_before, deadline)
  end

  defp do_await_consistent_connection(upstream, reg_name, dynsup_pid, conn_pid_before, deadline) do
    pid = UpstreamRegistry.connection_for(upstream, reg_name)

    child_pids =
      try do
        DynamicSupervisor.which_children(dynsup_pid)
        |> Enum.map(fn {_id, p, _type, _mods} -> p end)
      catch
        :exit, _ -> []
      end

    cond do
      not is_pid(pid) ->
        retry_consistent_connection(upstream, reg_name, dynsup_pid, conn_pid_before, deadline)

      not Process.alive?(pid) ->
        retry_consistent_connection(upstream, reg_name, dynsup_pid, conn_pid_before, deadline)

      pid not in child_pids ->
        retry_consistent_connection(upstream, reg_name, dynsup_pid, conn_pid_before, deadline)

      pid == conn_pid_before ->
        retry_consistent_connection(upstream, reg_name, dynsup_pid, conn_pid_before, deadline)

      true ->
        pid
    end
  end

  defp retry_consistent_connection(upstream, reg_name, dynsup_pid, conn_pid_before, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk(
        "Connection for #{upstream} never reached a stable post-cascade state " <>
          "(alive AND child of new DynSup AND pid != pre-cascade pid). " <>
          "Last seen: registered=#{inspect(UpstreamRegistry.connection_for(upstream, reg_name))}, " <>
          "children=#{inspect(safe_which_children(dynsup_pid))}, " <>
          "pre=#{inspect(conn_pid_before)}"
      )
    else
      receive do
      after
        10 -> :ok
      end

      do_await_consistent_connection(upstream, reg_name, dynsup_pid, conn_pid_before, deadline)
    end
  end

  defp safe_which_children(dynsup_pid) do
    DynamicSupervisor.which_children(dynsup_pid)
    |> Enum.map(fn {_id, p, _type, _mods} -> p end)
  catch
    :exit, _ -> :unavailable
  end
end
