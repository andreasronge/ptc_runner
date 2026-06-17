defmodule PtcRunner.PreludeStoreChurnSoakTest do
  @moduledoc """
  Soak test: a long-lived `PtcRunner.PreludeStore` driven through many
  write / prune / `set_default` cycles must reach a bounded steady state.

  Unlike the `Lisp.run/2`-driven soaks (`closure_capture`, `atom_leak`,
  `tracer`) — which exercise the *stateless*, per-call-reaped sandbox — the
  prelude store is **node-lifetime state**: a single owner GenServer plus a
  private ETS table whose growth is meant to be bounded by `:max_versions`,
  `:max_ids`, and `:max_total_bytes`. The server tracks retained-byte
  accounting by hand (`total_bytes`, `version_bytes`, `current_bytes`,
  `latest_bytes`, `pinned_versions`) and must keep those maps in step with the
  ETS rows as old versions are pruned. Drift there is invisible to the existing
  suite, so this soak guards it directly.

  ## Scenarios

    1. **Version churn (no pinning)** — round-robin novel versions across a
       fixed id set with a small `:max_versions` window. Pruning must release
       both ETS rows and the matching accounting entries: ETS, total, and the
       *store process* memory must all flatten once the window is full. Novel
       ids/sources must not intern atoms on the compile path.

    2. **`set_default` re-pinning a kept version** — keep promoting the same
       early version as default while new versions roll past it. The pinned
       set stays constant, so retention (window + the one pin) stays flat.

    3. **Distinct-version pinning fails closed** — pinning a *brand-new*
       version every round defeats the `:max_versions` window (pinned versions
       are retained), so growth must be capped by `:max_total_bytes` and surface
       as `:store_bytes_exceeded`, not unbounded heap. Validates the one growth
       vector the window does not bound.

  ## Run

      mix test --only soak test/soak/prelude_store_churn_soak_test.exs

      PTC_SOAK_ITERATIONS=5000 \\
        mix test --only soak test/soak/prelude_store_churn_soak_test.exs
  """
  use ExUnit.Case, async: false

  alias PtcRunner.PreludeStore
  alias PtcRunner.TestSupport.MemorySoak

  @moduletag :soak
  @moduletag timeout: :infinity

  @ids ~w(alpha beta gamma delta epsilon)

  setup do
    {:ok, iters: MemorySoak.iteration_count()}
  end

  test "bounded version churn across many ids reaches steady state", %{iters: iters} do
    {:ok, store} = PreludeStore.new(max_versions: 4)

    {before, mid, aft} =
      measure_store(store, iters, fn {_phase, i} ->
        id = Enum.at(@ids, rem(i, length(@ids)))
        assert {:ok, %{id: ^id}} = PreludeStore.write(store, id, version_source(id, i))
      end)

    log("version-churn", iters, before, mid, aft)

    # Pruning must release retained rows (ETS) and free their bytes (total).
    MemorySoak.assert_flat!(mid, aft, :ets, tolerance_pct: 25)
    MemorySoak.assert_flat!(mid, aft, :total, tolerance_pct: 25)
    # The server's hand-rolled byte accounting must prune in lockstep.
    assert_store_mem_flat!(mid, aft)
    # Novel ids/sources must not intern atoms on the compile path.
    MemorySoak.assert_atoms_per_iter_strict!(before, mid, aft, iters, max_per_iter: 0.5)
    # Compilation runs in per-write reaped sandbox processes — none must leak.
    MemorySoak.assert_procs_stable!(before, aft, tolerance: 5)
  end

  test "set_default re-pinning a kept version stays bounded", %{iters: iters} do
    {:ok, store} = PreludeStore.new(max_versions: 4)
    # Seed v1 on every id; it stays pinned as default for the whole run.
    Enum.each(@ids, fn id ->
      assert {:ok, %{version: 1}} = PreludeStore.write(store, id, version_source(id, 0))
    end)

    {before, mid, aft} =
      measure_store(store, iters, fn {_phase, i} ->
        id = Enum.at(@ids, rem(i, length(@ids)))
        assert {:ok, %{}} = PreludeStore.write(store, id, version_source(id, i))
        # Re-pin the same kept version each round — pinned set stays {1}, so
        # retention is the rolling window plus one fixed pin.
        assert {:ok, %{current_version: 1}} = PreludeStore.set_default(store, id, 1)
      end)

    log("set-default-repin", iters, before, mid, aft)

    MemorySoak.assert_flat!(mid, aft, :ets, tolerance_pct: 25)
    MemorySoak.assert_flat!(mid, aft, :total, tolerance_pct: 25)
    assert_store_mem_flat!(mid, aft)
    MemorySoak.assert_atoms_per_iter_strict!(before, mid, aft, iters, max_per_iter: 0.5)
    MemorySoak.assert_procs_stable!(before, aft, tolerance: 5)
  end

  test "distinct-version pinning fails closed without unbounded growth", %{iters: iters} do
    # Small store so pinning a new version every round saturates quickly. Each
    # pin retains its (large, compiled) version row past the window, so the
    # store must cap at max_total_bytes rather than climbing forever.
    {:ok, store} = PreludeStore.new(max_versions: 2, max_total_bytes: 200_000)

    assert saturate_with_pins(store, "alpha") == :saturated

    {before, mid, aft} =
      measure_store(store, iters, fn {_phase, i} ->
        # Keep trying to grow: any write that slips through gets pinned too.
        case PreludeStore.write(store, "alpha", version_source("alpha", 100_000 + i)) do
          {:ok, %{version: version}} ->
            _ = PreludeStore.set_default(store, "alpha", version)

          {:error, %{reason: :store_bytes_exceeded}} ->
            :ok
        end
      end)

    log("distinct-pin-saturated", iters, before, mid, aft)

    # Still capped: a fresh distinct-version write must fail closed.
    assert {:error, %{reason: :store_bytes_exceeded}} =
             PreludeStore.write(store, "alpha", version_source("alpha", 999_999))

    # And memory must be flat now that the store is saturated.
    MemorySoak.assert_flat!(mid, aft, :ets, tolerance_pct: 25)
    MemorySoak.assert_flat!(mid, aft, :total, tolerance_pct: 25)
    assert_store_mem_flat!(mid, aft)
  end

  # Drives warmup + measured iterations like `MemorySoak.measure3/3`, but each
  # snapshot also records the store owner process's own memory so accounting-map
  # drift (version_bytes/current_bytes/latest_bytes/pinned_versions) is visible.
  defp measure_store(store, n, fun) when n >= 2 do
    warmup = env_int("PTC_SOAK_WARMUP", 10)
    Enum.each(1..max(warmup, 1), fn i -> fun.({:warmup, i}) end)
    before = snap(store)
    fun.({:measured, 1})
    mid = snap(store)
    Enum.each(2..n, fn i -> fun.({:measured, i}) end)
    aft = snap(store)
    {before, mid, aft}
  end

  # `MemorySoak.snapshot/0` already GCs every process (including the store
  # owner), so the store memory read here is post-GC.
  defp snap(store) do
    s = MemorySoak.snapshot()
    {:memory, store_mem} = Process.info(store.pid, :memory)
    Map.put(s, :store_mem, store_mem)
  end

  defp assert_store_mem_flat!(before, aft, opts \\ []) do
    tolerance_pct = Keyword.get(opts, :tolerance_pct, 25)
    b = before.store_mem
    a = aft.store_mem
    growth_pct = if b == 0, do: 0.0, else: (a - b) * 100 / b

    if growth_pct > tolerance_pct do
      raise ExUnit.AssertionError,
        message:
          "Prelude store owner memory grew #{Float.round(growth_pct, 1)}% " <>
            "(#{MemorySoak.format_bytes(b)} → #{MemorySoak.format_bytes(a)}), " <>
            "tolerance #{tolerance_pct}%. The server's byte-accounting maps " <>
            "(version_bytes/current_bytes/latest_bytes/pinned_versions) likely " <>
            "are not pruning in step with the ETS rows."
    end

    :ok
  end

  # Pins a fresh version each round until the store reports it is saturated.
  defp saturate_with_pins(store, id) do
    Enum.reduce_while(1..10_000, :unsaturated, fn n, _acc ->
      with {:ok, %{version: version}} <- PreludeStore.write(store, id, version_source(id, n)),
           {:ok, _} <- PreludeStore.set_default(store, id, version) do
        {:cont, :unsaturated}
      else
        {:error, %{reason: :store_bytes_exceeded}} -> {:halt, :saturated}
      end
    end)
  end

  defp version_source(id, n) do
    """
    (ns #{id} "Soak prelude #{id}.")

    (defn inspect [] {:version #{n}})
    (defn value [] #{n})
    """
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil ->
        default

      str ->
        case Integer.parse(str) do
          {n, ""} -> n
          _ -> default
        end
    end
  end

  defp log(label, iters, before, mid, aft) do
    IO.puts("BEFORE (#{label}, n=#{iters}):\n#{MemorySoak.format(before)}")
    IO.puts("MID    (#{label}, n=#{iters}):\n#{MemorySoak.format(mid)}")
    IO.puts("AFTER  (#{label}, n=#{iters}):\n#{MemorySoak.format(aft)}")

    IO.puts(
      "store owner mem: #{MemorySoak.format_bytes(before.store_mem)} → " <>
        "#{MemorySoak.format_bytes(mid.store_mem)} → " <>
        "#{MemorySoak.format_bytes(aft.store_mem)}"
    )
  end
end
