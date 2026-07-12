defmodule PtcRunner.Kernel.BundleCompiler do
  @moduledoc false

  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Lisp.Parser
  alias PtcRunner.Lisp.Prelude.Compiler

  @max_components 128
  @max_edges 512
  @max_source_bytes 2_000_000

  @spec compile([Component.t()]) :: {:ok, FrozenBundle.t()} | {:error, map()}
  def compile(components) when is_list(components) do
    with :ok <- bounded_components(components),
         {:ok, by_id} <- unique_ids(components),
         :ok <- dependencies_exist(by_id),
         {:ok, ordered} <- topological_order(by_id),
         {:ok, compiled} <- describe_ordered(ordered),
         {:ok, prelude} <- compile_prelude(ordered, compiled) do
      ids = Enum.map(compiled, & &1.id)

      hash =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary(Enum.map(compiled, &{&1.id, &1.source_hash}))
        )
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

  def compile(_components), do: {:error, %{reason: :invalid_components}}

  defp bounded_components(components) do
    if Enum.all?(components, &match?(%Component{}, &1)) do
      total_bytes = Enum.reduce(components, 0, &(&2 + byte_size(&1.source)))
      edges = Enum.reduce(components, 0, &(&2 + length(&1.dependencies)))

      if length(components) <= @max_components and total_bytes <= @max_source_bytes and
           edges <= @max_edges,
         do: :ok,
         else: {:error, %{reason: :bundle_limit_exceeded}}
    else
      {:error, %{reason: :invalid_components}}
    end
  end

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
    do_topological_order(by_id, MapSet.new(), [])
  end

  defp do_topological_order(by_id, resolved, ordered) do
    if map_size(by_id) == MapSet.size(resolved) do
      {:ok, Enum.reverse(ordered)}
    else
      ready =
        by_id
        |> Map.values()
        |> Enum.reject(&MapSet.member?(resolved, &1.id))
        |> Enum.filter(&MapSet.subset?(MapSet.new(&1.dependencies), resolved))
        |> Enum.sort_by(& &1.id)

      case ready do
        [] ->
          {:error, %{reason: :component_cycle}}

        [component | _] ->
          do_topological_order(by_id, MapSet.put(resolved, component.id), [component | ordered])
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

  defp error_message(%{message: message}) when is_binary(message),
    do: String.slice(message, 0, 4_096)

  defp error_message(error), do: inspect(error, limit: 10, printable_limit: 4_096)
end
