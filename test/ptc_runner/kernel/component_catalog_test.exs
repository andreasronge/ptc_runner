defmodule PtcRunner.Kernel.ComponentCatalogTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.ComponentCatalog
  alias PtcRunner.Kernel.ComponentOverride
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunBuilder
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.SourceIntern
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude

  @marker "CATALOG-SOURCE-MARKER-7f3c9a1e"

  test "empty catalog is attested and bindable without a bundle" do
    catalog = ComponentCatalog.empty()

    assert ComponentCatalog.valid?(catalog)
    assert ComponentCatalog.empty?(catalog)
    assert ComponentCatalog.ids(catalog) == []
    assert ComponentCatalog.fetch(catalog, "missing") == :error
    assert {:ok, empty} = ComponentCatalog.bind(nil, nil)
    assert ComponentCatalog.empty?(empty)
  end

  test "build projects frozen order, graph, namespaces, and qualified hashes" do
    base = component!("base", "(ns base) (defn value [] 1)")
    consumer = component!("consumer", "(ns consumer) (defn answer [] (base/value))", ["base"])
    {:ok, bundle} = Kernel.compile_bundle([consumer, base])
    {:ok, _intern, catalog} = ComponentCatalog.build([consumer, base], bundle)

    assert ComponentCatalog.valid?(catalog)
    assert ComponentCatalog.ids(catalog) == bundle.component_ids
    assert {:ok, entry} = ComponentCatalog.fetch(catalog, "consumer")
    assert entry.dependencies == ["base"]
    assert entry.namespaces == ["consumer"]
    assert entry.source == consumer.source
    assert entry.source_hash == ComponentOverride.hash(consumer.source)
    assert String.match?(entry.source_hash, ~r/\Asha256:[0-9a-f]{64}\z/)

    frozen = Enum.find(bundle.components, &(&1.id == "consumer"))
    assert frozen.source_hash == String.replace_prefix(entry.source_hash, "sha256:", "")
  end

  test "omitted catalog remains valid for existing environment constructors" do
    {:ok, bundle} = Kernel.compile_bundle([component!("app", "(ns app) (def value 1)")])

    assert {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    assert {:ok, mission} = MissionEnvironment.new(bundle: bundle)
    assert ComponentCatalog.empty?(workflow.catalog)
    assert ComponentCatalog.empty?(mission.catalog)
    assert WorkflowEnvironment.valid?(workflow)
    assert MissionEnvironment.valid?(mission)
  end

  test "environment attestation includes the bound catalog" do
    {_components, bundle, catalog} = compiled_catalog()

    assert {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, catalog: catalog)
    assert {:ok, mission} = MissionEnvironment.new(bundle: bundle, catalog: catalog)
    assert workflow.catalog == catalog
    assert mission.catalog == catalog
    assert WorkflowEnvironment.valid?(workflow)
    assert MissionEnvironment.valid?(mission)

    mutated = %{workflow | catalog: ComponentCatalog.empty()}
    refute WorkflowEnvironment.valid?(mutated)
    refute MissionEnvironment.valid?(%{mission | catalog: ComponentCatalog.empty()})
  end

  test "catalog and bundle substitution fail closed" do
    {_components, bundle, catalog} = compiled_catalog()
    {_other, other_bundle, other_catalog} = other_compiled_catalog()

    assert {:error, :catalog_bundle_mismatch} =
             WorkflowEnvironment.new(bundle: bundle, catalog: other_catalog)

    assert {:error, :catalog_bundle_mismatch} =
             MissionEnvironment.new(bundle: other_bundle, catalog: catalog)

    assert {:error, :catalog_bundle_mismatch} = ComponentCatalog.bind(catalog, other_bundle)
    assert {:error, :catalog_bundle_mismatch} = ComponentCatalog.build([], bundle)
    assert {:error, :catalog_bundle_mismatch} = ComponentCatalog.build([:not_a_component], bundle)
  end

  test "source-hash mismatch against the frozen bundle is rejected" do
    original = component!("app", "(ns app) (def value 1)")
    {:ok, bundle} = Kernel.compile_bundle([original])
    mutated = %{original | source: "(ns app) (def value 2)"}

    assert {:error, :catalog_bundle_mismatch} = ComponentCatalog.build([mutated], bundle)
  end

  test "same id and source with a changed dependency edge is rejected" do
    base = component!("base", "(ns base) (defn value [] 1)")
    consumer = component!("consumer", "(ns consumer) (defn answer [] (base/value))", ["base"])
    {:ok, bundle} = Kernel.compile_bundle([consumer, base])
    disconnected = %{consumer | dependencies: []}

    assert {:error, :catalog_bundle_mismatch} =
             ComponentCatalog.build([disconnected, base], bundle)
  end

  test "a non-empty component list cannot bind to a nil bundle" do
    component = component!("app", "(ns app) (def value 1)")

    assert {:error, :catalog_bundle_mismatch} =
             ComponentCatalog.build([component], nil)
  end

  test "a guarded hash collision fails closed" do
    intern = SourceIntern.new()
    source = "(ns app) (def value 1)"
    hash = ComponentOverride.hash(source)
    {:ok, _interned, intern} = SourceIntern.intern(intern, source)

    assert {:error, :source_hash_collision} =
             SourceIntern.intern_hash(intern, hash, "(ns app) (def value 2)")

    {:ok, first, intern} = SourceIntern.intern(intern, source)
    {:ok, second, _intern} = SourceIntern.intern(intern, source)
    assert :erts_debug.same(first, second)

    component = component!("app", source)
    {:ok, _intern, [interned]} = SourceIntern.intern_components(intern, [component])
    assert interned.source == source
    assert :erts_debug.same(interned.source, first)
  end

  @tag :tmp_dir
  test "catalog source is the acquired package bytes after a later file mutation", %{
    tmp_dir: directory
  } do
    acquired = """
    (ns app)
    (defn run [input] (return "#{@marker}"))
    """

    mutated = """
    (ns app)
    (defn run [input] (return "MUTATED-AFTER-ACQUIRE"))
    """

    documents = fixture_documents(acquired)
    manifest_path = write_documents(directory, documents)

    assert {:ok, request} =
             ApplicationPackage.request_directory(manifest_path, result_projection: :native)

    File.write!(Path.join(directory, "workflow.clj"), mutated)

    {:ok, registry} = ProviderRegistry.new()
    assert {:ok, built} = RunBuilder.build(request, registry)

    catalog = built.config.workflow_environment.catalog
    assert {:ok, entry} = ComponentCatalog.fetch(catalog, "app")
    assert entry.source == acquired
    refute entry.source =~ "MUTATED-AFTER-ACQUIRE"
    assert :ok = RunBuilder.close(built)
  end

  test "ordinary Kernel results, traces, and prelude summaries omit catalog source" do
    source = """
    (ns app)
    (defn run [input] (return 42))
    ; #{@marker}
    """

    component = component!("app", source)
    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, _intern, catalog} = ComponentCatalog.build([component], bundle)
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, catalog: catalog)
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "catalog-disclosure")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, result} = Kernel.run("(return (app/run {}))", config)
    assert result.value == 42

    public = inspect(%{result: result, events: EventSink.events(sink)})
    refute public =~ @marker

    summary = inspect(Prelude.trace_summary(bundle.prelude))
    refute summary =~ @marker
    refute summary =~ source

    {:ok, step} = Lisp.run("(return 1)", prelude: bundle.prelude)
    refute inspect(step) =~ @marker
  end

  test "interned source binaries stay shared across independently allocated copies" do
    text = large_source("shared", @marker)
    first_copy = :binary.copy(text)
    second_copy = :binary.copy(text)
    refute :erts_debug.same(first_copy, second_copy)

    first = component!("shared", first_copy)
    second = %{first | source: second_copy}
    {:ok, bundle} = Kernel.compile_bundle([first])

    intern = SourceIntern.new()
    {:ok, intern, first_catalog} = ComponentCatalog.build([first], bundle, intern)
    {:ok, _intern, second_catalog} = ComponentCatalog.build([second], bundle, intern)
    {:ok, first_entry} = ComponentCatalog.fetch(first_catalog, "shared")
    {:ok, second_entry} = ComponentCatalog.fetch(second_catalog, "shared")
    assert :erts_debug.same(first_entry.source, second_entry.source)

    # Sending a refc binary creates a new local ProcBin, so :erts_debug.same/2
    # is false after receive; the payload stays off-heap when size stays tiny.
    assert byte_size(first_entry.source) > 8_000
    assert :erts_debug.size(first_entry.source) < 16
    assert :erts_debug.flat_size(first_entry.source) < 16

    parent = self()

    spawn(fn ->
      send(parent, first_entry.source)
    end)

    assert_receive spawned_source
    assert spawned_source == first_entry.source
    assert :erts_debug.size(spawned_source) < 16
    assert :erts_debug.flat_size(spawned_source) < 16
    assert byte_size(spawned_source) == byte_size(first_entry.source)
  end

  @tag :tmp_dir
  test "sixteen acquired missions intern independently read equal source files", %{
    tmp_dir: directory
  } do
    source = large_source("mission", @marker)
    documents = sixteen_mission_documents(source)
    manifest_path = write_documents(directory, documents)

    assert {:ok, request} =
             ApplicationPackage.request_directory(manifest_path, result_projection: :native)

    package_sources =
      request.package.missions
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_name, spec} -> hd(spec.components).source end)

    assert length(package_sources) == 16
    first_package = hd(package_sources)
    assert Enum.all?(package_sources, &:erts_debug.same(first_package, &1))

    {:ok, registry} = ProviderRegistry.new()
    assert {:ok, built} = RunBuilder.build(request, registry)

    catalog_sources =
      built.config.missions
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_name, %{environment: environment}} ->
        {:ok, entry} = ComponentCatalog.fetch(environment.catalog, "mission")
        entry.source
      end)

    assert length(catalog_sources) == 16
    first_catalog = hd(catalog_sources)
    assert Enum.all?(catalog_sources, &:erts_debug.same(first_catalog, &1))
    assert :erts_debug.same(first_package, first_catalog)
    assert :ok = RunBuilder.close(built)
  end

  test "direct Lisp.run strips an injected catalog" do
    {_components, _bundle, catalog} = compiled_catalog()

    assert Lisp.public_run_opts(component_catalog: catalog, timeout: 1_000) == [timeout: 1_000]
    refute Keyword.has_key?(Lisp.public_run_opts(component_catalog: catalog), :component_catalog)

    {:ok, step} = Lisp.run("(return 1)", component_catalog: catalog)
    refute inspect(step) =~ @marker
  end

  test "a near-limit catalog evaluates through the sandbox as shared setup memory" do
    source = near_limit_source("app", @marker)
    component = component!("app", source)
    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, _intern, catalog} = ComponentCatalog.build([component], bundle)
    {:ok, entry} = ComponentCatalog.fetch(catalog, "app")

    assert byte_size(entry.source) > 1_800_000
    assert :erts_debug.size(entry.source) < 16

    assert {:ok, without} =
             Lisp.run_native("(+ 1 2)", prelude: bundle.prelude, timeout: 10_000)

    assert {:ok, with_catalog} =
             Lisp.run_native("(+ 1 2)",
               prelude: bundle.prelude,
               component_catalog: catalog,
               timeout: 10_000
             )

    assert with_catalog.return == 3
    refute inspect(with_catalog) =~ @marker
    assert is_integer(without.usage.baseline_bytes)
    assert is_integer(with_catalog.usage.baseline_bytes)

    # One shared catalog may appear in the setup baseline; many copies must not.
    assert with_catalog.usage.baseline_bytes <
             without.usage.baseline_bytes + byte_size(entry.source) + 65_536

    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, catalog: catalog)
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "catalog-sandbox-heap")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, result} = Kernel.run("(return 1)", config)
    assert result.value == 1
    refute inspect(%{result: result, events: EventSink.events(sink)}) =~ @marker
  end

  defp compiled_catalog do
    source = """
    (ns app)
    (defn run [input] (return 1))
    ; #{@marker}
    """

    component = component!("app", source)
    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, _intern, catalog} = ComponentCatalog.build([component], bundle)
    {[component], bundle, catalog}
  end

  defp other_compiled_catalog do
    component = component!("other", "(ns other) (defn run [input] (return 2))")
    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, _intern, catalog} = ComponentCatalog.build([component], bundle)
    {[component], bundle, catalog}
  end

  defp large_source(ns, marker, padding_bytes \\ 8_192) do
    padding = String.duplicate("x", padding_bytes)
    "(ns #{ns})\n(def marker \"#{marker}\")\n(def padding \"#{padding}\")\n"
  end

  defp near_limit_source(ns, marker) do
    padding = String.duplicate("x", 1_850_000)
    "(ns #{ns})\n(defn run [input] (return 1))\n; #{marker}\n; #{padding}\n"
  end

  defp component!(id, source, dependencies \\ []) do
    {:ok, component} = Component.new(id: id, source: source, dependencies: dependencies)
    component
  end

  defp sixteen_mission_documents(source) do
    workflow = """
    (ns app)
    (defn run [input] (return input))
    """

    missions =
      Map.new(1..16, fn index ->
        name = mission_name(index)

        {name,
         %{
           "components" => [%{"id" => "mission", "path" => "#{name}.clj", "dependencies" => []}]
         }}
      end)

    mission_files =
      Map.new(1..16, fn index ->
        {mission_name(index) <> ".clj", :binary.copy(source)}
      end)

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "workflow.clj", "dependencies" => []}],
        "entry" => "app/run"
      },
      "missions" => missions,
      "input" => %{"value" => %{}},
      "providers" => %{"workflow" => [], "mission" => []}
    }

    Map.merge(
      %{
        "app.json" => Jason.encode!(manifest),
        "workflow.clj" => workflow
      },
      mission_files
    )
  end

  defp mission_name(index),
    do: "m" <> String.pad_leading(Integer.to_string(index), 2, "0")

  defp fixture_documents(source) do
    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "workflow.clj", "dependencies" => []}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{"workflow" => [], "mission" => []}
    }

    %{
      "app.json" => Jason.encode!(manifest),
      "workflow.clj" => source
    }
  end

  defp write_documents(directory, documents) do
    Enum.each(documents, fn {name, bytes} ->
      path = Path.join(directory, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end)

    Path.join(directory, "app.json")
  end
end
