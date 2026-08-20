defmodule PtcRunner.Bench.PreludeBundleCharacterization do
  @moduledoc false

  alias PtcRunner.Bench.Baseline
  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude.Compiler

  @default_samples 7
  @scale_counts [1, 5, 14, 20, 64, 128]

  def run do
    samples = positive_env!("PTC_PRELUDE_BENCH_SAMPLES", @default_samples)
    all = library_components!()
    agent_core = Library.resolve_components([{:library, "agent.core"}]) |> ok!()
    mixed = mixed_components!(agent_core)

    IO.puts("PTC-Lisp bundle characterization")
    IO.puts("samples=#{samples}")
    IO.inspect(Baseline.provenance(), label: "provenance")

    characterize("all shipped", all, samples)
    characterize("agent.core closure", agent_core, samples)
    characterize("mixed shipped/custom/override", mixed, samples)
    scaling(samples)
    repeated_preparation(agent_core, samples)
    execution_proxy(agent_core, samples)
  end

  defp characterize(label, components, samples) do
    ordered = order_components!(components)
    descriptions = describe_components!(ordered)
    compiled = compile_descriptions!(ordered, descriptions)
    source = Enum.map_join(ordered, "\n", & &1.source)
    namespace_deps = namespace_dependencies(compiled)
    metadata = component_metadata(compiled)
    composed = Compiler.compose(Enum.map(compiled, & &1.prelude), source, metadata) |> ok!()
    frozen = frozen_bundle!(compiled, composed, :metadata_only)
    retained = frozen_bundle!(compiled, composed, :compiled_components)

    phases = [
      phase("component validation", samples, fn -> validate_components!(components) end),
      phase("component description", samples, fn -> describe_components!(ordered) end),
      phase("per-component compilation", samples, fn ->
        compile_descriptions!(ordered, descriptions)
      end),
      phase("aggregate recompilation", samples, fn ->
        Compiler.compile_unlocated(source, namespace_deps: namespace_deps) |> ok!()
      end),
      phase("artifact composition", samples, fn ->
        Compiler.compose(Enum.map(compiled, & &1.prelude), source, metadata) |> ok!()
      end),
      phase("metadata-only sealing", samples, fn ->
        frozen_bundle!(compiled, composed, :metadata_only)
      end),
      phase("callable-component sealing proxy", samples, fn ->
        frozen_bundle!(compiled, composed, :compiled_components)
      end),
      phase("full bundle compilation", samples, fn ->
        Kernel.compile_bundle(components) |> ok!()
      end)
    ]

    IO.puts(
      "\n#{label} (#{length(components)} components, #{source_bytes(components)} source bytes)"
    )

    IO.puts("phase | median wall us | median retained process heap bytes | result external bytes")

    Enum.each(phases, fn row ->
      IO.puts("#{row.name} | #{row.wall_us} | #{row.heap_bytes} | #{row.external_bytes}")
    end)

    by_name = Map.new(phases, &{&1.name, &1.wall_us})

    legacy_proxy =
      Enum.sum([
        by_name["component validation"],
        by_name["component description"],
        by_name["per-component compilation"],
        by_name["aggregate recompilation"],
        by_name["callable-component sealing proxy"]
      ])

    composed_proxy =
      Enum.sum([
        by_name["component validation"],
        by_name["component description"],
        by_name["per-component compilation"],
        by_name["artifact composition"],
        by_name["metadata-only sealing"]
      ])

    IO.puts("phase-sum preparation proxy | wall us")
    IO.puts("aggregate-recompile/callable-retention proxy | #{legacy_proxy}")
    IO.puts("composed/metadata-only proxy | #{composed_proxy}")

    IO.puts("artifact | external bytes")
    IO.puts("aggregate prelude | #{:erlang.external_size(composed)}")
    IO.puts("metadata-only components | #{:erlang.external_size(frozen.components)}")
    IO.puts("retained callable components | #{:erlang.external_size(retained.components)}")
    IO.puts("metadata-only frozen bundle | #{:erlang.external_size(frozen)}")
    IO.puts("callable-component frozen proxy | #{:erlang.external_size(retained)}")
  end

  defp scaling(samples) do
    IO.puts("\nsynthetic component-count scaling")
    IO.puts("components | source bytes | median full preparation us | external bytes")

    Enum.each(@scale_counts, fn count ->
      components = synthetic_components(count, 0)
      row = phase("scale", min(samples, 3), fn -> Kernel.compile_bundle(components) |> ok!() end)

      IO.puts("#{count} | #{source_bytes(components)} | #{row.wall_us} | #{row.external_bytes}")
    end)
  end

  defp repeated_preparation(components, samples) do
    identical =
      median_wall_us(samples, fn ->
        Kernel.compile_bundle(components) |> ok!()
      end)

    distinct =
      1..samples
      |> Enum.map(fn revision ->
        changed = replace_leaf_source(components, revision)
        wall_us(fn -> Kernel.compile_bundle(changed) |> ok!() end)
      end)
      |> Baseline.median()

    IO.puts("\nrepeated preparation")
    IO.puts("identical bundle median wall us | #{identical}")
    IO.puts("distinct identity median wall us | #{distinct}")
    IO.puts("scope | no global cache; both rows exercise ordinary bounded compilation")
  end

  # This pure call crosses the shipped agent.core closure and evaluator without
  # provider/model latency. It is an execution-overhead proxy, not a claim to
  # reproduce an external model turn; compare it with real replay telemetry
  # before considering a second execution backend.
  defp execution_proxy(components, samples) do
    bundle = Kernel.compile_bundle(components) |> ok!()

    tools =
      bundle.prelude.exports
      |> Enum.flat_map(& &1.requires)
      |> Enum.map(&String.replace_prefix(&1, "tool:", ""))
      |> Enum.uniq()
      |> Map.new(&{&1, fn _arguments -> nil end})

    wall =
      median_wall_us(samples, fn ->
        Lisp.run("(agent.feedback/turn-budget 4 2)", prelude: bundle.prelude, tools: tools)
        |> ok!()
      end)

    IO.puts("\nagent.core execution proxy")
    IO.puts("pure shipped closure median wall us | #{wall}")
  end

  defp phase(name, samples, fun) do
    fun.()

    measurements =
      for _sample <- 1..samples do
        measured_process(fun)
      end

    %{
      name: name,
      wall_us: measurements |> Enum.map(& &1.wall_us) |> Baseline.median(),
      heap_bytes: measurements |> Enum.map(& &1.heap_bytes) |> Baseline.median(),
      external_bytes: measurements |> Enum.map(& &1.external_bytes) |> Baseline.median()
    }
  end

  defp measured_process(fun) do
    caller = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        {:memory, before_bytes} = Process.info(self(), :memory)
        started = System.monotonic_time()
        result = fun.()
        elapsed = System.monotonic_time() - started
        {:memory, after_bytes} = Process.info(self(), :memory)

        send(caller, {
          self(),
          %{
            wall_us: System.convert_time_unit(elapsed, :native, :microsecond),
            heap_bytes: max(after_bytes - before_bytes, 0),
            external_bytes: :erlang.external_size(result)
          }
        })
      end)

    receive do
      {^pid, measurement} ->
        receive do
          {:DOWN, ^monitor, :process, ^pid, :normal} ->
            measurement

          {:DOWN, ^monitor, :process, ^pid, reason} ->
            raise "benchmark worker failed: #{inspect(reason)}"
        end

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        raise "benchmark worker exited before reporting: #{inspect(reason)}"
    end
  end

  defp validate_components!(components) do
    Enum.map(components, fn component ->
      Component.new(
        id: component.id,
        source: component.source,
        dependencies: component.dependencies,
        origin: component.origin
      )
      |> ok!()
    end)
  end

  defp describe_components!(ordered) do
    Map.new(ordered, fn component ->
      {component.id, Compiler.describe_unlocated(component.source) |> ok!()}
    end)
  end

  defp compile_descriptions!(ordered, descriptions) do
    Enum.reduce(ordered, [], fn component, compiled ->
      dependencies = Enum.filter(compiled, &(&1.id in component.dependencies))
      namespaces = Map.fetch!(descriptions, component.id).namespaces

      dependency_namespaces =
        dependencies |> Enum.flat_map(& &1.namespaces) |> Enum.uniq() |> Enum.sort()

      namespace_deps = Map.new(namespaces, &{&1, dependency_namespaces})

      prelude =
        Compiler.compile_description(Map.fetch!(descriptions, component.id),
          deps: Enum.map(dependencies, & &1.prelude),
          namespace_deps: namespace_deps
        )
        |> ok!()

      compiled ++
        [
          %{
            id: component.id,
            dependencies: component.dependencies,
            origin: component.origin,
            source_hash: hash(component.source),
            namespaces: namespaces,
            prelude: prelude
          }
        ]
    end)
  end

  defp frozen_bundle!(compiled, prelude, retention) do
    components =
      case retention do
        :metadata_only -> Enum.map(compiled, &Map.delete(&1, :prelude))
        :compiled_components -> compiled
      end

    hash = FrozenBundle.identity(components) |> ok!()

    %FrozenBundle{
      components: components,
      component_ids: Enum.map(components, & &1.id),
      hash: hash,
      prelude: prelude
    }
    |> FrozenBundle.seal()
  end

  defp namespace_dependencies(compiled) do
    by_id = Map.new(compiled, &{&1.id, &1})

    compiled
    |> Enum.flat_map(fn component ->
      dependencies =
        component.dependencies
        |> Enum.flat_map(&Map.fetch!(by_id, &1).namespaces)
        |> Enum.uniq()
        |> Enum.sort()

      Enum.map(component.namespaces, &{&1, dependencies})
    end)
    |> Map.new()
  end

  defp component_metadata(compiled),
    do: Enum.map(compiled, &Map.take(&1, [:id, :origin, :source_hash, :namespaces]))

  defp order_components!(components), do: order_components!(components, MapSet.new(), [])

  defp order_components!(components, resolved, ordered) do
    if length(ordered) == length(components) do
      Enum.reverse(ordered)
    else
      ready =
        components
        |> Enum.reject(&MapSet.member?(resolved, &1.id))
        |> Enum.filter(&Enum.all?(&1.dependencies, fn id -> MapSet.member?(resolved, id) end))
        |> Enum.sort_by(& &1.id)

      case ready do
        [component | _rest] ->
          order_components!(components, MapSet.put(resolved, component.id), [component | ordered])

        [] ->
          raise "benchmark components are not a closed acyclic graph"
      end
    end
  end

  defp library_components!, do: Library.components(Library.component_ids()) |> ok!()

  defp mixed_components!(agent_core) do
    overridden =
      Enum.map(agent_core, fn
        %Component{id: "agent.prompt"} = component ->
          %{
            component
            | source: component.source <> "\n;; benchmark override\n",
              origin: "benchmark:override"
          }

        component ->
          component
      end)

    custom =
      Component.new(
        id: "bench.custom",
        dependencies: ["agent.core"],
        origin: "benchmark:custom",
        source: "(ns bench.custom) (defn answer [] 42)"
      )
      |> ok!()

    [custom | overridden]
  end

  defp synthetic_components(count, revision) do
    Enum.map(1..count, fn index ->
      id = "synthetic.#{index}"

      Component.new(
        id: id,
        origin: "benchmark:synthetic",
        source: "(ns #{id}) (defn value [] #{index + revision})"
      )
      |> ok!()
    end)
  end

  defp replace_leaf_source(components, revision) do
    leaf = components |> Enum.filter(&(&1.dependencies == [])) |> Enum.min_by(& &1.id)

    Enum.map(components, fn
      %Component{id: id} = component when id == leaf.id ->
        %{component | source: component.source <> "\n;; identity #{revision}\n"}

      component ->
        component
    end)
  end

  defp median_wall_us(samples, fun) do
    fun.()
    1..samples |> Enum.map(fn _sample -> wall_us(fun) end) |> Baseline.median()
  end

  defp wall_us(fun) do
    started = System.monotonic_time()
    fun.()
    System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
  end

  defp source_bytes(components), do: Enum.sum(Enum.map(components, &byte_size(&1.source)))
  defp hash(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  defp ok!({:ok, value}), do: value
  defp ok!({:error, reason}), do: raise("benchmark operation failed: #{inspect(reason)}")

  defp positive_env!(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 -> integer
          _invalid -> raise "#{name} must be a positive integer"
        end
    end
  end
end

PtcRunner.Bench.PreludeBundleCharacterization.run()
