defmodule PtcRunner.AtomLeakSoakTest do
  @moduledoc """
  Targeted soak: feeds **novel** symbol / keyword / ns-symbol names
  into `Lisp.run/2` on every iteration. Each iteration must NOT grow
  the atom table — atoms never GC, so any per-iteration interning is
  an unbounded-input leak.

  This is the regression test for [#953](https://github.com/andreasronge/ptc_runner/issues/953).

  PTC-Lisp's parser currently interns every var, symbol, and keyword
  name via `String.to_atom/1` (see `lib/ptc_runner/lisp/parser_helpers.ex`,
  `lib/ptc_runner/lisp/ast.ex`), so this test is **expected to fail
  on the pre-fix code**. After the audited call sites switch to
  `String.to_existing_atom/1` (or move to binary keys), the rate
  should drop to ~0 atoms/iter.

  ## Why three programs

  Each tests a distinct AST shape:

    1. **`let`-bound variable** — exercises the `:var` parser path
       (`parser_helpers.ex:55`).
    2. **Keyword literal** — exercises the `:keyword` parser path
       (`parser_helpers.ex:51` + `ast.ex:22`).
    3. **Naked symbol reference** — exercises the `:symbol` /
       `:ns_symbol` path (`ast.ex:40,44,47,51`).

  ## Run

      mix test --only soak test/soak/atom_leak_soak_test.exs

      PTC_SOAK_ITERATIONS=1000 \\
        mix test --only soak test/soak/atom_leak_soak_test.exs
  """
  use ExUnit.Case, async: false

  alias PtcRunner.Lisp
  alias PtcRunner.TestSupport.MemorySoak

  # Tagged `:skip` because this regression test currently fails — it
  # reproduces the leak described in
  # https://github.com/andreasronge/ptc_runner/issues/953. Run
  # explicitly with `mix test --include skip --include soak
  # test/soak/atom_leak_soak_test.exs` to reproduce.
  # Remove the `:skip` tag once #953 is fixed.
  @moduletag :soak
  @moduletag :skip
  @moduletag timeout: :infinity

  setup do
    {:ok, iters: MemorySoak.iteration_count()}
  end

  test "novel var names do not grow the atom table", %{iters: iters} do
    {before, mid, aft} =
      MemorySoak.measure3(iters, fn {_phase, i} ->
        program = "(let [my_uniq_#{i} 42] my_uniq_#{i})"
        assert {:ok, %{return: 42}} = Lisp.run(program)
      end)

    log("novel-vars", iters, before, mid, aft)
    MemorySoak.assert_atoms_per_iter_strict!(before, mid, aft, iters, max_per_iter: 0.5)
  end

  test "novel keyword literals do not grow the atom table", %{iters: iters} do
    {before, mid, aft} =
      MemorySoak.measure3(iters, fn {_phase, i} ->
        # `:kw_<i>` is a fresh keyword on every iteration. The keyword
        # is the program's return value, so it must round-trip — that
        # forces the parser to actually intern it.
        program = "(identity :kw_#{i})"
        assert {:ok, _} = Lisp.run(program)
      end)

    log("novel-keywords", iters, before, mid, aft)
    MemorySoak.assert_atoms_per_iter_strict!(before, mid, aft, iters, max_per_iter: 0.5)
  end

  test "novel data-key access paths do not grow the atom table", %{iters: iters} do
    # `data/key_N` is a `:ns_symbol` — the namespace `data` is a fixed
    # vocabulary atom, but the key portion is parsed via
    # `ast.ex:47` which calls `String.to_atom(key)`. This is the
    # nastiest leak: every distinct context-key an LLM emits in a
    # `data/foo` reference creates a permanent atom.
    {before, mid, aft} =
      MemorySoak.measure3(iters, fn {_phase, i} ->
        key = "ctx_key_#{i}"
        program = "data/#{key}"
        # We don't supply the key in context, so the program returns
        # nil — but the parser still interned `:"ctx_key_N"`.
        assert {:ok, %{return: nil}} = Lisp.run(program, context: %{})
      end)

    log("novel-ns-symbols", iters, before, mid, aft)
    MemorySoak.assert_atoms_per_iter_strict!(before, mid, aft, iters, max_per_iter: 0.5)
  end

  defp log(label, iters, before, mid, aft) do
    first = mid.atoms - before.atoms
    steady = aft.atoms - mid.atoms
    rate = if iters > 1, do: Float.round(steady / (iters - 1), 3), else: 0.0

    IO.puts(
      "atom-leak soak [#{label}, n=#{iters}]: " <>
        "first_iter=+#{first} atoms, " <>
        "steady (iters 2..#{iters})=+#{steady} atoms, " <>
        "rate=#{rate}/iter"
    )
  end
end
