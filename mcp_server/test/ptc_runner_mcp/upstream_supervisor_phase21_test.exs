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
      # Attempt cap: 30. The DynSup's restart budget is `max_restarts: 2
      # / max_seconds: 60`, so 3 abnormal exits inside the 60s window
      # trip it. Each iteration takes at most ~60ms (50ms wait branch
      # + monitor handling), so 30 attempts ≈ 1.8s wall-clock — well
      # inside the 60s window with plenty of headroom for parallel-test
      # scheduling jitter. Pre-bump (cap=12) flaked under load when
      # several iterations consecutively hit the "Registry hasn't yet
      # re-registered" wait branch.
      crash_until_dynsup_dies!(reg_name, upstream, dynsup_ref, 30)

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
  # DynamicSupervisor exhausts its restart intensity and exits. Each
  # iteration waits for the per-Connection :DOWN before issuing the
  # next kill (no Process.sleep). The DynSup's :DOWN, when it
  # arrives, is also received here — we re-send it to ourselves so
  # the main test body can match on its monitor ref via
  # assert_receive.
  defp crash_until_dynsup_dies!(_reg_name, _upstream, _dynsup_ref, 0) do
    flunk("DynamicSupervisor restart-intensity not exhausted after attempts")
  end

  defp crash_until_dynsup_dies!(reg_name, upstream, dynsup_ref, attempts_left) do
    case UpstreamRegistry.connection_for(upstream, reg_name) do
      nil ->
        # Connection slot is empty — either it's between restarts,
        # or the DynSup just died and the cascade is in progress.
        # Wait briefly for either re-register or the DynSup DOWN.
        receive do
          {:DOWN, ^dynsup_ref, :process, _, _} = msg ->
            send(self(), msg)
            :ok
        after
          50 -> crash_until_dynsup_dies!(reg_name, upstream, dynsup_ref, attempts_left - 1)
        end

      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} ->
            crash_until_dynsup_dies!(reg_name, upstream, dynsup_ref, attempts_left - 1)

          {:DOWN, ^dynsup_ref, :process, _, _} = msg ->
            # DynSup died first (or simultaneously) — re-queue the
            # message for the main test body and stop crashing.
            send(self(), msg)
            :ok
        after
          2_000 -> flunk("Connection #{inspect(pid)} did not die after :kill")
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

  defp await_connection!(upstream, reg_name, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_connection(upstream, reg_name, deadline)
  end

  defp do_await_connection(upstream, reg_name, deadline) do
    case UpstreamRegistry.connection_for(upstream, reg_name) do
      pid when is_pid(pid) ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Connection for #{upstream} never reappeared after Registry restart")
        else
          receive do
          after
            10 -> :ok
          end

          do_await_connection(upstream, reg_name, deadline)
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
