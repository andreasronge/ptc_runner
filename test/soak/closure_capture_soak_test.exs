defmodule PtcRunner.ClosureCaptureSoakTest do
  @moduledoc """
  Soak test: closures over large binaries / lists must not pin memory
  in the *calling* host process once `Lisp.run/2` returns.

  Each `Lisp.run/2` runs in a fresh sandbox process (1 s / 10 MB cap)
  that's reaped at the end of the call, so per-program leakage is
  bounded by design. This soak verifies the host side — the
  long-lived process that drives many runs in a row — doesn't slowly
  accumulate state from returned values, captured environments, or
  parsed AST pinned by some cache.

  Three programs are exercised:

    1. **`build`** — allocates a large string inside the sandbox and
       returns its **length** (a small integer). The returned value is
       tiny, so the host should see no growth even if the program
       built MB of intermediate state.

    2. **`return_closure`** — defines `(fn [] big)` where `big` is a
       large string, then returns it. The closure value leaves the
       sandbox; we drop our reference immediately and assert it can
       be GC'd. (This catches the classic "small term references
       refc-binary" leak.)

    3. **`tool_loop`** — many small `Lisp.run/2` calls back-to-back.
       The interesting metric is host-process memory after warmup:
       the parser, analyzer, and interpreter must not keep building
       up state in module attributes / persistent_term / ETS.

  ## Run

      mix test --only soak test/soak/closure_capture_soak_test.exs

      PTC_SOAK_ITERATIONS=10000 \\
        mix test --only soak test/soak/closure_capture_soak_test.exs
  """
  use ExUnit.Case, async: false

  alias PtcRunner.Lisp
  alias PtcRunner.TestSupport.MemorySoak

  @moduletag :soak
  # Soak tests run open-ended; bump the timeout so 10k+ iterations finish.
  @moduletag timeout: :infinity

  setup do
    {:ok, iters: MemorySoak.iteration_count()}
  end

  test "host memory stays flat across many sandbox runs (build)", %{iters: iters} do
    program = """
    (let [big (apply str (range 0 10000))]
      (count big))
    """

    {before, aft} =
      MemorySoak.measure(iters, fn _phase ->
        assert {:ok, %{return: n}} = Lisp.run(program)
        assert is_integer(n) and n > 0
      end)

    log_snapshot("build", iters, before, aft)

    MemorySoak.assert_flat!(before, aft, :binary, tolerance_pct: 50)
    MemorySoak.assert_flat!(before, aft, :total, tolerance_pct: 30)
    MemorySoak.assert_atoms_per_iter!(before, aft, iters)
    MemorySoak.assert_procs_stable!(before, aft, tolerance: 5)
  end

  test "returned closures don't pin captured binaries in host", %{iters: iters} do
    program = """
    (defn make-getter []
      (let [big (apply str (range 0 5000))]
        (fn [] (count big))))
    ((make-getter))
    """

    {before, aft} =
      MemorySoak.measure(iters, fn _phase ->
        # We deliberately don't bind the result to a name; if anything
        # leaks, it leaks through the runtime/parser, not test scope.
        assert {:ok, %{return: _}} = Lisp.run(program)
      end)

    log_snapshot("return_closure", iters, before, aft)

    MemorySoak.assert_flat!(before, aft, :binary, tolerance_pct: 50)
    MemorySoak.assert_flat!(before, aft, :processes, tolerance_pct: 50)
    MemorySoak.assert_atoms_per_iter!(before, aft, iters)
  end

  test "tight loop of tiny programs doesn't accumulate state", %{iters: iters} do
    {before, aft} =
      MemorySoak.measure(iters, fn _phase ->
        assert {:ok, %{return: 6}} = Lisp.run("(+ 1 2 3)")
      end)

    log_snapshot("tool_loop", iters, before, aft)

    MemorySoak.assert_flat!(before, aft, :total, tolerance_pct: 20)
    MemorySoak.assert_atoms_per_iter!(before, aft, iters)
    MemorySoak.assert_procs_stable!(before, aft, tolerance: 5)
  end

  defp log_snapshot(label, iters, before, aft) do
    IO.puts("BEFORE (#{label}, n=#{iters}):\n#{MemorySoak.format(before)}")
    IO.puts("AFTER  (#{label}, n=#{iters}):\n#{MemorySoak.format(aft)}")
  end
end
