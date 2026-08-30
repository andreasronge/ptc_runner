defmodule PtcRunner.Kernel.BundleCompositionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.BundleCompiler
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude.Compiler

  @base_source """
  (ns base "Base helpers.")

  (defn- offset [value] (+ value 2))
  (defn make-adder [value] (fn [extra] (offset (+ value extra))))
  """

  @consumer_source """
  (ns consumer "Consumer helpers.")

  (defn answer [] ((base/make-adder 39) 1))
  """

  test "described source compiles without reparsing through the public source path" do
    assert {:ok, description} = Compiler.describe_unlocated(@base_source)
    assert description.namespaces == ["base"]
    assert {:ok, described} = Compiler.compile_description(description)
    assert {:ok, ordinary} = Compiler.compile_unlocated(@base_source)

    assert Map.take(described, [:namespaces, :exports, :form_graph, :metadata, :source_hash]) ==
             Map.take(ordinary, [:namespaces, :exports, :form_graph, :metadata, :source_hash])
  end

  test "composed component artifacts preserve aggregate protected facts and runtime behavior" do
    base = component!("base", @base_source)
    consumer = component!("consumer", @consumer_source, ["base"])

    assert {:ok, bundle} = Kernel.compile_bundle([consumer, base])

    aggregate_source = @base_source <> "\n" <> @consumer_source

    assert {:ok, fresh} =
             Compiler.compile_unlocated(aggregate_source,
               namespace_deps: %{"base" => [], "consumer" => ["base"]}
             )

    assert Map.take(bundle.prelude, [:namespaces, :exports, :form_graph, :source_hash]) ==
             Map.take(fresh, [:namespaces, :exports, :form_graph, :source_hash])

    assert bundle.prelude.metadata.namespaces == fresh.metadata.namespaces

    assert Enum.sort(Map.keys(bundle.prelude.private_env)) ==
             Enum.sort(Map.keys(fresh.private_env))

    for prelude <- [bundle.prelude, fresh] do
      assert {:ok, step} = Lisp.run("(consumer/answer)", prelude: prelude)
      assert step.return == 42
    end
  end

  test "preparation-local reuse still honors the shared absolute deadline" do
    component = component!("base", @base_source)
    assert {:ok, bundle} = Kernel.compile_bundle([component])

    assert {:error, {%{reason: :bundle_compile_timeout}, [^component]}} =
             BundleCompiler.compile_named(
               %{"mission" => %{components: [component]}},
               System.monotonic_time(:millisecond) - 1,
               0,
               4_000_000,
               [{[component], bundle}]
             )
  end

  defp component!(id, source, dependencies \\ []) do
    {:ok, component} = Component.new(id: id, source: source, dependencies: dependencies)
    component
  end
end
