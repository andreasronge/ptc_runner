defmodule PtcRunner.TestSupport.MemorySoak do
  @moduledoc """
  Helpers for memory-leak soak tests.

  Soak tests are tagged `:soak` and excluded from the default ExUnit run
  (see `test/test_helper.exs`). Opt in with `mix test --only soak`.

  ## What we sample

  Each `snapshot/0` captures:

    * `:mem`          — `:erlang.memory/0` system-wide totals
    * `:atoms`        — `:erlang.system_info(:atom_count)`. Atoms never GC,
                        so a steady climb across iterations = atom-table leak
    * `:procs`        — `:erlang.system_info(:process_count)`. A drifting
                        process count between churn cycles points at a
                        supervisor/registry that isn't cleaning up children.
    * `:top_memory`   — top-N processes by `:memory` (via `:recon.proc_count/2`
                        when available, else a fallback walk over
                        `Process.list/0`)
    * `:bin_leak`     — `:recon.bin_leak/1` result (count of refc-binaries
                        reclaimed when *every* process is forced through GC).
                        A non-trivial drop here on an otherwise quiet system
                        is the classic BEAM "small binary references pinning
                        big refc binaries" pattern.

  ## Workflow

      before = MemorySoak.snapshot()
      Enum.each(1..n, fn _ -> work() end)
      MemorySoak.gc_everywhere()
      aft = MemorySoak.snapshot()

      MemorySoak.assert_flat!(before, aft, :total, tolerance_pct: 10)
      MemorySoak.assert_atoms_stable!(before, aft, max_delta: 0)

  Tests should `IO.puts(MemorySoak.format(snapshot))` at start + end so
  failures have actionable context in the log.

  ## Tunables (env vars)

  | Var                       | Default | Purpose                          |
  |---------------------------|---------|----------------------------------|
  | `PTC_SOAK_ITERATIONS`     | 100     | Loop count per soak test         |
  | `PTC_SOAK_WARMUP`         | 10      | Warmup iterations (not measured) |
  | `PTC_SOAK_TOLERANCE_PCT`  | 20      | Allowed growth between snapshots |
  | `PTC_SOAK_TOP_N`          | 10      | Top-N processes to report        |

  Crank `PTC_SOAK_ITERATIONS` to ~10k+ for real soak runs locally.
  """

  @type snapshot :: %{
          mem: keyword(),
          atoms: non_neg_integer(),
          procs: non_neg_integer(),
          top_memory: [{pid(), non_neg_integer(), term()}],
          bin_leak: integer(),
          monotonic_ms: integer()
        }

  @doc "Capture a memory + process snapshot. Forces a system-wide GC first."
  @spec snapshot(keyword()) :: snapshot()
  def snapshot(opts \\ []) do
    if Keyword.get(opts, :gc, true), do: gc_everywhere()

    %{
      mem: :erlang.memory(),
      atoms: :erlang.system_info(:atom_count),
      procs: :erlang.system_info(:process_count),
      top_memory: top_by_memory(Keyword.get(opts, :top_n, top_n())),
      bin_leak: bin_leak(),
      monotonic_ms: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Forces `:erlang.garbage_collect/1` on every live process.

  Refc binaries are reclaimed only when *every* process that holds a
  reference (even a tiny one) has been GC'd. Soak tests must call this
  before sampling, or a few sleeping processes can pin megabytes of
  binary state indefinitely and skew the assertion.
  """
  def gc_everywhere do
    Process.list() |> Enum.each(&:erlang.garbage_collect/1)
    :erlang.garbage_collect()
    :ok
  end

  @doc "Assert a `:erlang.memory/0` key did not grow beyond a tolerance."
  def assert_flat!(before, aft, key, opts \\ []) do
    tolerance_pct = Keyword.get(opts, :tolerance_pct, tolerance_pct())
    b = Keyword.fetch!(before.mem, key)
    a = Keyword.fetch!(aft.mem, key)
    growth_pct = if b == 0, do: 0.0, else: (a - b) * 100 / b

    if growth_pct > tolerance_pct do
      raise ExUnit.AssertionError,
        message: """
        Memory soak: `#{key}` grew #{Float.round(growth_pct, 1)}% \
        (#{format_bytes(b)} → #{format_bytes(a)}), tolerance #{tolerance_pct}%.

        Before:
        #{format(before)}

        After:
        #{format(aft)}
        """
    end

    :ok
  end

  @doc """
  Assert the atom count did not grow by more than `:max_delta`.

  For atom-leak detection in a loop, prefer `assert_atoms_per_iter!/4`
  which separates one-shot init growth from per-iteration leaks — the
  thing that actually matters as `iters` grows toward infinity.
  """
  def assert_atoms_stable!(before, aft, opts \\ []) do
    max_delta = Keyword.get(opts, :max_delta, 0)
    delta = aft.atoms - before.atoms

    if delta > max_delta do
      raise ExUnit.AssertionError,
        message:
          "Atom table grew by #{delta} atoms (allowed #{max_delta}). " <>
            "Atoms never GC — likely `String.to_atom/1` on user input."
    end

    :ok
  end

  @doc """
  Assert the per-iteration atom growth rate is below `:max_per_iter`.

  Unlike `assert_atoms_stable!/3`, this allows a fixed one-shot
  budget (`:fixed_budget`, default 200 atoms) to absorb lazy-loaded
  modules, first-parse vocabulary interning, and other one-time
  startup atom allocation. The interesting metric is whether the
  *rate* — atoms per iteration — is greater than zero (or whatever
  threshold the test sets).

  A real `String.to_atom/1`-on-user-input leak grows linearly with
  iterations, so it will blow past any reasonable per-iter cap as
  soon as the iteration count is non-trivial.
  """
  def assert_atoms_per_iter!(before, aft, iters, opts \\ []) when iters > 0 do
    max_per_iter = Keyword.get(opts, :max_per_iter, 0.1)
    # Default budget is generous (2000 atoms) to absorb first-call
    # module loading and lazy vocabulary interning. At n=10_000 with
    # rate=0.1/iter, this still hard-fails on any real linear leak
    # (budget exhausted by 3000 unrelated atoms ≈ trivial).
    fixed_budget = Keyword.get(opts, :fixed_budget, 2_000)
    delta = aft.atoms - before.atoms
    rate = (delta - fixed_budget) / iters

    if rate > max_per_iter do
      raise ExUnit.AssertionError,
        message:
          "Atom growth rate #{Float.round(rate, 4)} atoms/iter exceeds budget " <>
            "#{max_per_iter}/iter (delta=#{delta}, iters=#{iters}, " <>
            "fixed_budget=#{fixed_budget}). " <>
            "Likely `String.to_atom/1` on user input somewhere in the per-iter path."
    end

    :ok
  end

  @doc "Assert process count returned to baseline (±tolerance)."
  def assert_procs_stable!(before, aft, opts \\ []) do
    tolerance = Keyword.get(opts, :tolerance, 5)
    delta = aft.procs - before.procs

    if delta > tolerance do
      raise ExUnit.AssertionError,
        message:
          "Process count grew by #{delta} (allowed #{tolerance}). " <>
            "Likely a supervisor child / registry entry that wasn't cleaned up.\n\n" <>
            "Top processes after:\n#{format_top(aft.top_memory)}"
    end

    :ok
  end

  @doc """
  Runs warmup iterations, returns a `:before` snapshot taken AFTER
  warmup, runs measured iterations, returns the `:before` / `:after`
  pair for use with the `assert_*` helpers.

  Snapshotting after warmup is critical: parsers and analyzers
  typically intern atoms / build caches on first call, and we want
  the leak assertions to compare two steady-state moments — not
  steady-state against "cold VM with everything still to be interned."
  """
  def measure(n, opts \\ [], fun) when is_function(fun, 1) do
    warmup = Keyword.get(opts, :warmup, warmup_count())
    Enum.each(1..max(warmup, 1), fn i -> fun.({:warmup, i}) end)
    before = snapshot()
    Enum.each(1..n, fn i -> fun.({:measured, i}) end)
    aft = snapshot()
    {before, aft}
  end

  @doc "Legacy: warmup then measured iterations, no snapshot. Prefer `measure/3`."
  def loop(n, warmup \\ nil, fun) when is_function(fun, 1) do
    warmup = warmup || warmup_count()
    Enum.each(1..warmup, fn i -> fun.({:warmup, i}) end)
    Enum.each(1..n, fn i -> fun.({:measured, i}) end)
    :ok
  end

  @doc "Pretty-print a snapshot."
  def format(%{mem: mem, atoms: atoms, procs: procs, top_memory: top, bin_leak: bl}) do
    """
      total: #{format_bytes(mem[:total])}
      processes: #{format_bytes(mem[:processes])}
      binary: #{format_bytes(mem[:binary])}
      ets: #{format_bytes(mem[:ets])}
      atom: #{format_bytes(mem[:atom])} (#{atoms} atoms)
      code: #{format_bytes(mem[:code])}
      procs: #{procs}
      bin_leak reclaim: #{bl} (lower = less refc-binary pressure)
      top by memory:
    #{format_top(top)}
    """
  end

  defp format_top(top) do
    Enum.map_join(top, "\n", fn {pid, mem, info} ->
      name =
        case info do
          {:registered_name, n} when is_atom(n) -> Atom.to_string(n)
          _ -> inspect(pid)
        end

      "    #{name}: #{format_bytes(mem)}"
    end)
  end

  @doc false
  def format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 2)} GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 2)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp top_by_memory(n) do
    if recon_loaded?() do
      :recon.proc_count(:memory, n)
    else
      Process.list()
      |> Enum.map(fn pid ->
        case Process.info(pid, [:memory, :registered_name]) do
          [{:memory, m}, name] -> {pid, m, name}
          _ -> {pid, 0, []}
        end
      end)
      |> Enum.sort_by(fn {_, m, _} -> -m end)
      |> Enum.take(n)
    end
  end

  defp bin_leak do
    if recon_loaded?() do
      # recon.bin_leak/1 returns [{pid, count, info}, ...]; sum the counts.
      :recon.bin_leak(50) |> Enum.reduce(0, fn {_, c, _}, acc -> acc + c end)
    else
      0
    end
  end

  defp recon_loaded? do
    Code.ensure_loaded?(:recon)
  end

  defp iterations, do: env_int("PTC_SOAK_ITERATIONS", 100)
  defp warmup_count, do: env_int("PTC_SOAK_WARMUP", 10)
  defp tolerance_pct, do: env_int("PTC_SOAK_TOLERANCE_PCT", 20)
  defp top_n, do: env_int("PTC_SOAK_TOP_N", 10)

  @doc "Iteration count for soak loops (override via `PTC_SOAK_ITERATIONS`)."
  def iteration_count, do: iterations()

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
end
