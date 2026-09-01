defmodule PtcRunner.ComponentCatalogSoakTest do
  @moduledoc """
  Repeated catalog-backed sandbox setup must reuse interned source binaries
  rather than copying a per-environment aggregate into each evaluator.

  Resource model, written down before the workload:

  | resource | creator | owner | authorized user | closer |
  |---|---|---|---|---|
  | intern table | `setup_all` | the test process | catalog construction | discarded with the test process |
  | attested catalog | `setup_all` / each rebuild cycle | the test process | `Lisp.run_native/2` | GC after the cycle drops the rebuilt catalog |
  | sandbox evaluator | `Lisp.run_native/2` | itself | the caller | reaped when the call returns |

  Three independent measurements:

  * `usage.baseline_bytes` is captured in the live sandbox after its post-copy
    GC, before eval. One interned catalog may appear there; a second copy of
    the same source would exceed the per-call bound even though the child has
    exited by the time the soak snapshot runs. That baseline cannot tell a
    shared backing binary from a replacement copy of the same size.
  * Concurrent live evaluators compared against the same occupancy without a
    catalog: node-wide `:erlang.memory(:binary)` must stay below two source
    sizes, which is what distinguishes sharing from a per-sandbox copy.
  * Host `:binary` / `:total` after system-wide GC catch intern-table growth
    and copies that survive the child.
  """

  use ExUnit.Case, async: false

  @moduletag :soak
  @moduletag timeout: :infinity

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.ComponentCatalog
  alias PtcRunner.Kernel.SourceIntern
  alias PtcRunner.Lisp
  alias PtcRunner.TestSupport.CatalogTransport
  alias PtcRunner.TestSupport.MemorySoak

  @marker "catalog-soak-marker-9f2c1a70"
  @padding_bytes 262_144
  @copy_slack_bytes 65_536
  @live_evaluators 8

  setup_all do
    source = large_source()
    {:ok, component} = Component.new(id: "soak", source: source)
    {:ok, bundle} = Kernel.compile_bundle([component])
    intern = SourceIntern.new()
    {:ok, intern, catalog} = ComponentCatalog.build([component], bundle, intern)
    {:ok, interned} = ComponentCatalog.fetch(catalog, "soak")

    assert byte_size(interned.source) > @copy_slack_bytes * 2

    {:ok, without} =
      Lisp.run_native("(+ 1 2)", prelude: bundle.prelude, timeout: 10_000)

    {:ok,
     component: component,
     bundle: bundle,
     intern: intern,
     catalog: catalog,
     interned_source: interned.source,
     empty_baseline_bytes: without.usage.baseline_bytes}
  end

  setup do
    {:ok, iters: MemorySoak.iteration_count()}
  end

  test "repeated catalog-backed evaluations do not copy interned source", context do
    %{
      iters: iters,
      bundle: bundle,
      catalog: catalog,
      interned_source: interned_source,
      empty_baseline_bytes: empty_baseline_bytes
    } = context

    {before, aft} =
      MemorySoak.measure(iters, fn _phase ->
        assert {:ok, step} =
                 Lisp.run_native("(+ 1 2)",
                   prelude: bundle.prelude,
                   component_catalog: catalog,
                   timeout: 10_000
                 )

        assert step.return == 3
        refute inspect(step) =~ @marker
        refute_copied_catalog(step, empty_baseline_bytes, interned_source)
      end)

    log_snapshot("catalog evaluation", iters, before, aft)

    MemorySoak.assert_flat!(before, aft, :binary, tolerance_pct: 50)
    MemorySoak.assert_flat!(before, aft, :total, tolerance_pct: 30)
    MemorySoak.assert_atoms_per_iter!(before, aft, iters)
    MemorySoak.assert_procs_stable!(before, aft, tolerance: 5)
    assert :erts_debug.size(interned_source) < 16
  end

  test "rebuilding catalogs through one intern stays shared and flat", context do
    %{
      iters: iters,
      component: component,
      bundle: bundle,
      intern: intern,
      interned_source: interned_source,
      empty_baseline_bytes: empty_baseline_bytes
    } = context

    {before, aft} =
      MemorySoak.measure(iters, fn _phase ->
        first_copy = :binary.copy(component.source)
        second_copy = :binary.copy(component.source)
        refute :erts_debug.same(first_copy, second_copy)

        first = %{component | source: first_copy}
        second = %{component | source: second_copy}
        assert {:ok, intern, first_catalog} = ComponentCatalog.build([first], bundle, intern)
        assert {:ok, _intern, second_catalog} = ComponentCatalog.build([second], bundle, intern)
        assert {:ok, first_entry} = ComponentCatalog.fetch(first_catalog, "soak")
        assert {:ok, second_entry} = ComponentCatalog.fetch(second_catalog, "soak")
        assert :erts_debug.same(first_entry.source, second_entry.source)
        assert :erts_debug.size(first_entry.source) < 16

        assert {:ok, step} =
                 Lisp.run_native("(+ 1 2)",
                   prelude: bundle.prelude,
                   component_catalog: first_catalog,
                   timeout: 10_000
                 )

        assert step.return == 3
        refute_copied_catalog(step, empty_baseline_bytes, interned_source)
      end)

    log_snapshot("catalog rebuild", iters, before, aft)

    MemorySoak.assert_flat!(before, aft, :binary, tolerance_pct: 50)
    MemorySoak.assert_flat!(before, aft, :total, tolerance_pct: 30)
    MemorySoak.assert_atoms_per_iter!(before, aft, iters)
    MemorySoak.assert_procs_stable!(before, aft, tolerance: 5)
  end

  test "concurrent live evaluators share interned catalog bytes", context do
    %{bundle: bundle, catalog: catalog, interned_source: interned_source} = context

    CatalogTransport.assert_shared_interned_bytes!(
      @live_evaluators,
      [prelude: bundle.prelude],
      [prelude: bundle.prelude, component_catalog: catalog],
      byte_size(interned_source),
      @copy_slack_bytes
    )
  end

  defp refute_copied_catalog(step, empty_baseline_bytes, interned_source) do
    assert is_integer(step.usage.baseline_bytes)
    assert is_integer(empty_baseline_bytes)
    # One shared catalog may appear in the setup baseline; many copies must not.
    assert step.usage.baseline_bytes <
             empty_baseline_bytes + byte_size(interned_source) + @copy_slack_bytes
  end

  defp large_source do
    padding = String.duplicate("x", @padding_bytes)
    "(ns soak)\n(def marker \"#{@marker}\")\n(def padding \"#{padding}\")\n"
  end

  defp log_snapshot(label, iters, before, aft) do
    IO.puts("BEFORE (#{label}, n=#{iters}):\n#{MemorySoak.format(before)}")
    IO.puts("AFTER  (#{label}, n=#{iters}):\n#{MemorySoak.format(aft)}")
  end
end
