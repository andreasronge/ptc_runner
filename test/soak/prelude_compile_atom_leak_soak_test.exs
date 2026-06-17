defmodule PtcRunner.PreludeCompileAtomLeakSoakTest do
  @moduledoc """
  Targeted soak: compiles a **distinct** prelude source on every iteration
  with novel namespace, export, helper, argument, and keyword names. Each
  iteration must NOT grow the atom table — atoms never GC, so any per-iteration
  interning on the compile path is an unbounded-input leak.

  ## Why a dedicated compile soak

  `atom_leak_soak_test.exs` guards the `Lisp.run/2` parser path against the
  [#953](https://github.com/andreasronge/ptc_runner/issues/953) regression
  (interning every var/symbol/keyword via `String.to_atom/1`). Prelude
  compilation is a **separate** entry point: `Prelude.Compiler.compile/1`
  parses the source, analyzes it, and *evaluates* the definition forms to
  capture a private env — a longer pipeline than a plain `Lisp.run/2`.

  Prelude source is untrusted and unbounded (operators and verifier loops
  author new versions over the node's lifetime), and the compiler keeps names
  as binaries today (string-keyed namespaces/exports). Nothing else locks that
  invariant in: a stray `String.to_atom/1` reintroduced anywhere in the
  compile/analyze/eval path would silently turn every novel prelude name into a
  permanent atom. This soak is the regression guard for that.

  ## Run

      mix test --only soak test/soak/prelude_compile_atom_leak_soak_test.exs

      PTC_SOAK_ITERATIONS=2000 \\
        mix test --only soak test/soak/prelude_compile_atom_leak_soak_test.exs
  """
  use ExUnit.Case, async: false

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.TestSupport.MemorySoak

  @moduletag :soak
  @moduletag timeout: :infinity

  setup do
    {:ok, iters: MemorySoak.iteration_count()}
  end

  test "compiling novel prelude names does not grow the atom table", %{iters: iters} do
    {before, mid, aft} =
      MemorySoak.measure3(iters, fn {_phase, i} ->
        # Every identifier and keyword is fresh on this iteration: namespace,
        # public export, private helper, parameter, and the keyword literal in
        # the body. If any of these are interned via `String.to_atom/1`, the
        # atom table grows linearly with iterations.
        source = """
        (ns ns_#{i} "Soak prelude #{i}.")

        (defn export_#{i} [arg_#{i}] {:built :ok_#{i} :arg arg_#{i}})
        (defn- helper_#{i} [] [:tag_#{i} #{i}])
        """

        assert {:ok, %Prelude{namespaces: namespaces}} = Compiler.compile(source)
        assert namespaces == ["ns_#{i}"]
      end)

    log("compile-novel-names", iters, before, mid, aft)

    MemorySoak.assert_atoms_per_iter_strict!(before, mid, aft, iters, max_per_iter: 0.5)
  end

  defp log(label, iters, before, mid, aft) do
    first = mid.atoms - before.atoms
    steady = aft.atoms - mid.atoms
    rate = if iters > 1, do: Float.round(steady / (iters - 1), 3), else: 0.0

    IO.puts(
      "prelude-compile atom-leak soak [#{label}, n=#{iters}]: " <>
        "first_iter=+#{first} atoms, " <>
        "steady (iters 2..#{iters})=+#{steady} atoms, " <>
        "rate=#{rate}/iter"
    )
  end
end
