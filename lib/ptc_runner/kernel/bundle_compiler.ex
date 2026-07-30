defmodule PtcRunner.Kernel.BundleCompiler do
  @moduledoc """
  Internal implementation of `PtcRunner.Kernel.compile_bundle/1`.

  It bounds the closed component set, resolves its component-ID dependency DAG
  deterministically, compiles the combined prelude in a bounded worker, limits
  diagnostics and artifact size, and seals the resulting bundle.
  """

  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Lisp.Parser
  alias PtcRunner.Lisp.Prelude.Compiler

  @bundle_hash_domain <<"ptc.frozen-bundle.v2", 0>>
  @max_components 128
  @max_edges 512
  @max_source_bytes 2_000_000
  @compile_timeout_ms 5_000
  @compile_heap_words 8_000_000
  @max_artifact_bytes 4_000_000
  @max_diagnostic_bytes 65_536

  @spec compile([Component.t()]) :: {:ok, FrozenBundle.t()} | {:error, map()}
  @doc "Compiles and attests a bounded closed component set."
  def compile(components) when is_list(components) do
    with :ok <- bounded_components(components) do
      compile_bounded(components)
    end
  end

  def compile(_components), do: {:error, %{reason: :invalid_components}}

  defp compile_bounded(components) do
    case BoundedWorker.run(
           fn ->
             components
             |> compile_unconfined()
             |> enforce_result(@max_artifact_bytes, @max_diagnostic_bytes)
           end,
           timeout_ms: @compile_timeout_ms,
           max_heap_words: @compile_heap_words
         ) do
      {:ok, result} -> result
      {:error, :timeout} -> {:error, %{reason: :bundle_compile_timeout}}
      {:error, :heap_exceeded} -> {:error, %{reason: :bundle_compile_heap_exceeded}}
      {:error, :worker_failed} -> {:error, %{reason: :bundle_compile_failed}}
    end
  end

  defp compile_unconfined(components) do
    with {:ok, components} <- validate_components(components),
         {:ok, by_id} <- unique_ids(components),
         :ok <- dependencies_exist(by_id),
         {:ok, ordered} <- topological_order(by_id),
         {:ok, compiled} <- describe_ordered(ordered),
         {:ok, prelude} <- compile_prelude(ordered, compiled) do
      ids = Enum.map(compiled, & &1.id)

      hash =
        compiled
        |> bundle_hash_bytes()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      bundle = %FrozenBundle{
        components: compiled,
        component_ids: ids,
        hash: hash,
        prelude: prelude
      }

      {:ok, FrozenBundle.seal(bundle)}
    end
  end

  @doc false
  @spec enforce_result({:ok, term()} | {:error, term()}, pos_integer(), pos_integer()) ::
          {:ok, term()} | {:error, map()}
  def enforce_result({:ok, bundle}, max_artifact_bytes, _max_diagnostic_bytes) do
    if :erlang.external_size(bundle) <= max_artifact_bytes,
      do: {:ok, bundle},
      else: {:error, %{reason: :bundle_artifact_exceeded}}
  end

  def enforce_result({:error, diagnostic} = error, _max_artifact_bytes, max_diagnostic_bytes) do
    if :erlang.external_size(diagnostic) <= max_diagnostic_bytes,
      do: error,
      else: {:error, %{reason: :bundle_diagnostic_exceeded}}
  end

  defp bounded_components(components) do
    bounded_components(components, 0, 0, 0)
  end

  defp bounded_components([], _count, _source_bytes, _edges), do: :ok

  defp bounded_components(_components, count, _source_bytes, _edges)
       when count >= @max_components,
       do: {:error, %{reason: :bundle_limit_exceeded}}

  defp bounded_components(
         [%Component{source: source, dependencies: dependencies} | rest],
         count,
         source_bytes,
         edges
       )
       when is_binary(source) and is_list(dependencies) do
    next_source_bytes = source_bytes + byte_size(source)

    with true <- next_source_bytes <= @max_source_bytes,
         {:ok, next_edges} <- bounded_edge_count(dependencies, edges) do
      bounded_components(rest, count + 1, next_source_bytes, next_edges)
    else
      false -> {:error, %{reason: :bundle_limit_exceeded}}
      {:error, reason} -> {:error, %{reason: reason}}
    end
  end

  defp bounded_components(_components, _count, _source_bytes, _edges),
    do: {:error, %{reason: :invalid_components}}

  defp bounded_edge_count([], edges), do: {:ok, edges}

  defp bounded_edge_count(_dependencies, edges) when edges >= @max_edges,
    do: {:error, :bundle_limit_exceeded}

  defp bounded_edge_count([_dependency | rest], edges),
    do: bounded_edge_count(rest, edges + 1)

  defp bounded_edge_count(_improper, _edges), do: {:error, :invalid_components}

  defp validate_components(components) do
    Enum.reduce_while(components, {:ok, []}, fn component, {:ok, validated} ->
      case validate_component(component) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | validated]}}
        {:error, _reason} -> {:halt, {:error, %{reason: :invalid_components}}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      error -> error
    end
  end

  defp validate_component(%Component{} = component) do
    Component.new(
      id: component.id,
      source: component.source,
      dependencies: component.dependencies,
      origin: component.origin
    )
  end

  defp validate_component(_component), do: {:error, :invalid_component}

  defp unique_ids(components) do
    Enum.reduce_while(components, {:ok, %{}}, fn %Component{id: id} = component, {:ok, by_id} ->
      if Map.has_key?(by_id, id),
        do: {:halt, {:error, %{reason: :duplicate_component_id, id: id}}},
        else: {:cont, {:ok, Map.put(by_id, id, component)}}
    end)
  end

  defp dependencies_exist(by_id) do
    case Enum.find(Map.values(by_id), fn component ->
           Enum.any?(component.dependencies, &(not Map.has_key?(by_id, &1)))
         end) do
      nil -> :ok
      component -> {:error, %{reason: :missing_component_dependency, id: component.id}}
    end
  end

  defp topological_order(by_id) do
    do_topological_order(by_id, %{}, [])
  end

  defp do_topological_order(by_id, resolved, ordered) do
    if map_size(by_id) == map_size(resolved) do
      {:ok, Enum.reverse(ordered)}
    else
      ready =
        by_id
        |> Map.values()
        |> Enum.reject(&Map.has_key?(resolved, &1.id))
        |> Enum.filter(fn component ->
          Enum.all?(component.dependencies, &Map.has_key?(resolved, &1))
        end)
        |> Enum.sort_by(& &1.id)

      case ready do
        [] ->
          {:error, %{reason: :component_cycle}}

        [component | _] ->
          do_topological_order(by_id, Map.put(resolved, component.id, true), [component | ordered])
      end
    end
  end

  defp describe_ordered(components) do
    Enum.reduce_while(components, {:ok, []}, fn component, {:ok, compiled} ->
      with {:ok, namespaces} <- component_namespaces(component.source),
           dependencies = dependency_components(compiled, component.dependencies),
           namespace_deps =
             Map.new(namespaces, &{&1, dependency_namespaces(dependencies)}),
           {:ok, prelude} <-
             Compiler.compile(component.source,
               deps: Enum.map(dependencies, & &1.prelude),
               namespace_deps: namespace_deps
             ) do
        entry = %{
          id: component.id,
          dependencies: component.dependencies,
          origin: component.origin,
          source_hash: source_hash(component.source),
          namespaces: namespaces,
          prelude: prelude
        }

        {:cont, {:ok, [entry | compiled]}}
      else
        {:error, error} ->
          {:halt,
           {:error,
            %{
              reason: :component_compile_error,
              id: component.id,
              details: error_message(error)
            }}}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      error -> error
    end
  end

  defp dependency_components(compiled, dependency_ids) do
    compiled
    |> Enum.filter(&(&1.id in dependency_ids))
    |> Enum.sort_by(& &1.id)
  end

  defp dependency_namespaces(components) do
    components
    |> Enum.flat_map(& &1.namespaces)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp compile_prelude(components, compiled) do
    namespace_deps = namespace_dependencies(compiled)
    source = Enum.map_join(components, "\n", & &1.source)

    Compiler.compile(source, namespace_deps: namespace_deps)
    |> case do
      {:ok, prelude} ->
        metadata =
          Enum.map(compiled, fn component ->
            Map.take(component, [:id, :origin, :source_hash, :namespaces])
          end)

        {:ok, %{prelude | metadata: Map.put(prelude.metadata, :components, metadata)}}

      {:error, error} ->
        {:error, %{reason: :bundle_compile_error, details: error_message(error)}}
    end
  end

  defp namespace_dependencies(components) do
    by_id = Map.new(components, &{&1.id, &1})

    components
    |> Enum.flat_map(fn component ->
      dependency_namespaces =
        component.dependencies
        |> Enum.flat_map(&Map.fetch!(by_id, &1).namespaces)
        |> Enum.uniq()
        |> Enum.sort()

      Enum.map(component.namespaces, &{&1, dependency_namespaces})
    end)
    |> Map.new()
  end

  defp component_namespaces(source) do
    case Parser.parse(source) do
      {:ok, ast} ->
        namespaces = ast |> top_level_forms() |> Enum.flat_map(&namespace_form/1) |> Enum.uniq()

        if namespaces == [],
          do: {:error, "component declares no namespace"},
          else: {:ok, namespaces}

      {:error, error} ->
        {:error, inspect(error, limit: 10, printable_limit: 1_000)}
    end
  end

  defp top_level_forms({:program, forms}), do: forms
  defp top_level_forms(form), do: [form]

  defp namespace_form({:list, [{:symbol, name}, {:symbol, namespace} | _metadata]})
       when name in [:ns, "ns"],
       do: [to_string(namespace)]

  defp namespace_form(_form), do: []

  defp source_hash(source),
    do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

  defp bundle_hash_bytes(components) do
    records =
      components
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&bundle_component_record/1)

    IO.iodata_to_binary([@bundle_hash_domain, <<length(records)::unsigned-big-32>>, records])
  end

  defp bundle_component_record(component) do
    {:ok, payload} =
      DeterministicJSON.encode(
        {:object,
         [
           {"dependencies", Enum.sort(Enum.uniq(component.dependencies))},
           {"source_hash", component.source_hash}
         ]}
      )

    [
      <<0x01>>,
      <<byte_size(component.id)::unsigned-big-32>>,
      component.id,
      <<byte_size(payload)::unsigned-big-64>>,
      payload
    ]
  end

  defp error_message(%{message: message}) when is_binary(message),
    do: String.slice(message, 0, 4_096)

  defp error_message(error), do: inspect(error, limit: 10, printable_limit: 4_096)
end
