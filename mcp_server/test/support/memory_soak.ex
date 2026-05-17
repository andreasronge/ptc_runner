defmodule PtcRunnerMcp.TestSupport.MemorySoak do
  @moduledoc """
  Helpers for MCP server memory-leak soak tests.

  Self-contained copy of the soak harness — the parent `:ptc_runner`
  project's `test/support` is not compiled when `:ptc_runner` is used
  as a path dep here. Keep this in sync with
  `<repo-root>/test/support/memory_soak.ex` (the canonical version).

  See that module's `@moduledoc` for usage. Tunables (env vars):

  | Var                       | Default | Purpose                          |
  |---------------------------|---------|----------------------------------|
  | `PTC_SOAK_ITERATIONS`     | 100     | Loop count per soak test         |
  | `PTC_SOAK_WARMUP`         | 10      | Warmup iterations (not measured) |
  | `PTC_SOAK_TOLERANCE_PCT`  | 20      | Allowed growth between snapshots |
  | `PTC_SOAK_TOP_N`          | 10      | Top-N processes to report        |
  """

  @type snapshot :: %{
          mem: keyword(),
          atoms: non_neg_integer(),
          procs: non_neg_integer(),
          top_memory: [{pid(), non_neg_integer(), term()}],
          bin_leak: integer(),
          monotonic_ms: integer()
        }

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

  def gc_everywhere do
    Process.list() |> Enum.each(&:erlang.garbage_collect/1)
    :erlang.garbage_collect()
    :ok
  end

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

  def assert_atoms_per_iter!(before, aft, iters, opts \\ []) when iters > 0 do
    max_per_iter = Keyword.get(opts, :max_per_iter, 0.1)
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

  def measure(n, opts \\ [], fun) when is_function(fun, 1) do
    warmup = Keyword.get(opts, :warmup, warmup_count())
    Enum.each(1..max(warmup, 1), fn i -> fun.({:warmup, i}) end)
    before = snapshot()
    Enum.each(1..n, fn i -> fun.({:measured, i}) end)
    aft = snapshot()
    {before, aft}
  end

  def measure3(n, opts \\ [], fun) when is_function(fun, 1) and n >= 2 do
    warmup = Keyword.get(opts, :warmup, warmup_count())
    Enum.each(1..max(warmup, 1), fn i -> fun.({:warmup, i}) end)
    before = snapshot()
    fun.({:measured, 1})
    mid = snapshot()
    Enum.each(2..n, fn i -> fun.({:measured, i}) end)
    aft = snapshot()
    {before, mid, aft}
  end

  def assert_atoms_per_iter_strict!(before, mid, aft, n, opts \\ []) when n >= 2 do
    max_per_iter = Keyword.get(opts, :max_per_iter, 0.1)
    first_iter_cost = mid.atoms - before.atoms
    steady_delta = aft.atoms - mid.atoms
    rate = steady_delta / (n - 1)

    if rate > max_per_iter do
      raise ExUnit.AssertionError,
        message:
          "Atom growth rate #{Float.round(rate, 4)} atoms/iter exceeds budget " <>
            "#{max_per_iter}/iter " <>
            "(first_iter=#{first_iter_cost} atoms, " <>
            "steady_delta=#{steady_delta} atoms over #{n - 1} iters). " <>
            "This is a real per-iter atom leak — likely `String.to_atom/1` " <>
            "on user-derived input."
    end

    :ok
  end

  def loop(n, warmup \\ nil, fun) when is_function(fun, 1) do
    warmup = warmup || warmup_count()
    Enum.each(1..warmup, fn i -> fun.({:warmup, i}) end)
    Enum.each(1..n, fn i -> fun.({:measured, i}) end)
    :ok
  end

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
      :recon.bin_leak(50) |> Enum.reduce(0, fn {_, c, _}, acc -> acc + c end)
    else
      0
    end
  end

  defp recon_loaded?, do: Code.ensure_loaded?(:recon)

  def iteration_count, do: env_int("PTC_SOAK_ITERATIONS", 100)
  defp warmup_count, do: env_int("PTC_SOAK_WARMUP", 10)
  defp tolerance_pct, do: env_int("PTC_SOAK_TOLERANCE_PCT", 20)
  defp top_n, do: env_int("PTC_SOAK_TOP_N", 10)

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
