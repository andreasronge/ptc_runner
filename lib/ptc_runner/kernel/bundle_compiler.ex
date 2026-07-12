defmodule PtcRunner.Kernel.BundleCompiler do
  @moduledoc false

  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.FrozenBundle
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
         {:ok, compiled} <- compile_ordered(ordered) do
      ids = Enum.map(compiled, & &1.id)

      hash =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary(Enum.map(compiled, &{&1.id, &1.source_hash}))
        )
        |> Base.encode16(case: :lower)

      {:ok, %FrozenBundle{components: compiled, component_ids: ids, hash: hash}}
    end
  end

  def compile(_components), do: {:error, %{reason: :invalid_components}}

  defp bounded_components(components) do
    total_bytes =
      Enum.reduce(components, 0, fn %Component{source: source}, total ->
        total + byte_size(source)
      end)

    edges =
      Enum.reduce(components, 0, fn %Component{dependencies: dependencies}, total ->
        total + length(dependencies)
      end)

    if length(components) <= @max_components and total_bytes <= @max_source_bytes and
         edges <= @max_edges and
         Enum.all?(components, &match?(%Component{}, &1)),
       do: :ok,
       else: {:error, %{reason: :bundle_limit_exceeded}}
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

  defp compile_ordered(components) do
    Enum.reduce_while(components, {:ok, []}, fn component, {:ok, compiled} ->
      case Compiler.compile(component.source) do
        {:ok, prelude} ->
          entry = %{
            id: component.id,
            dependencies: component.dependencies,
            origin: component.origin,
            source_hash: prelude.source_hash,
            prelude: prelude
          }

          {:cont, {:ok, [entry | compiled]}}

        {:error, error} ->
          {:halt,
           {:error,
            %{
              reason: :component_compile_error,
              id: component.id,
              details: Exception.message(error)
            }}}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      error -> error
    end
  end
end
