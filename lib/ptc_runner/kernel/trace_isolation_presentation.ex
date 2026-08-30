defmodule PtcRunner.Kernel.TraceIsolationPresentation do
  @moduledoc false

  alias PtcRunner.Kernel.TraceDirectoryAdmission

  @max_examples 16
  @max_example_sources 8

  @spec metadata([TraceDirectoryAdmission.component()], MapSet.t(binary())) :: map()
  def metadata([], %MapSet{}), do: %{}

  def metadata(components, %MapSet{} = known_run_ids) when is_list(components) do
    examples = components |> Enum.take(@max_examples) |> Enum.map(&example/1)

    %{
      "isolation" => %{
        "component_count" => length(components),
        "source_count" => total_sources(components),
        "known_run_count" => MapSet.size(known_run_ids),
        "reasons" => reason_totals(components),
        "examples" => examples,
        "examples_omitted_count" => length(components) - length(examples)
      }
    }
  end

  @spec shrink(map()) :: {:ok, map()} | :exhausted
  def shrink(%{"isolation" => %{"examples" => []}}), do: :exhausted

  def shrink(%{"isolation" => %{"examples" => examples} = isolation} = metadata)
      when is_list(examples) do
    {leading, [last]} = Enum.split(examples, -1)

    next_isolation =
      case last["sources"] do
        [] ->
          isolation
          |> Map.put("examples", leading)
          |> Map.update!("examples_omitted_count", &(&1 + 1))

        sources ->
          next_last =
            last
            |> Map.put("sources", Enum.drop(sources, -1))
            |> Map.update!("sources_omitted_count", &(&1 + 1))

          Map.put(isolation, "examples", leading ++ [next_last])
      end

    {:ok, Map.put(metadata, "isolation", next_isolation)}
  end

  def shrink(_metadata), do: :exhausted

  defp example(component) do
    sources = Enum.take(component.source_names, @max_example_sources)

    %{
      "sources" => sources,
      "source_count" => component.source_count,
      "sources_omitted_count" => component.source_count - length(sources),
      "reasons" => Enum.map(component.reasons, &Atom.to_string/1)
    }
  end

  defp reason_totals(components) do
    TraceDirectoryAdmission.reason_order()
    |> Enum.flat_map(fn reason ->
      matching = Enum.filter(components, &(reason in &1.reasons))

      if matching == [] do
        []
      else
        [
          %{
            "reason" => Atom.to_string(reason),
            "component_count" => length(matching),
            "source_count" => total_sources(matching)
          }
        ]
      end
    end)
  end

  defp total_sources(components),
    do: Enum.reduce(components, 0, fn component, total -> total + component.source_count end)
end
