defmodule PtcRunner.Kernel.GeneratedSourceAssociation do
  @moduledoc false

  @type turn :: %{
          required(:id) => term(),
          required(:sequence) => integer(),
          required(:sources) => [term()]
        }

  @type source :: %{required(:sequence) => integer(), required(:source) => term()}

  @spec associate([turn()], [source()]) :: %{
          by_turn: %{term() => [{source(), boolean()}]},
          unresolved_count: non_neg_integer()
        }
  def associate(turns, sources) when is_list(turns) and is_list(sources) do
    occurrences =
      Enum.flat_map(turns, fn turn ->
        Enum.map(turn.sources, fn source ->
          %{turn_id: turn.id, sequence: turn.sequence, source: source}
        end)
      end)

    occurrences_by_source = Enum.group_by(occurrences, & &1.source)
    sources_by_source = Enum.group_by(sources, & &1.source)

    source_keys = Map.keys(occurrences_by_source)

    {by_turn, unresolved_count} =
      Enum.reduce(source_keys, {%{}, 0}, fn source_key, {associations, unresolved_count} ->
        matching_occurrences = Map.get(occurrences_by_source, source_key, [])

        first_occurrence_sequence =
          matching_occurrences |> Enum.min_by(& &1.sequence) |> Map.fetch!(:sequence)

        matching_sources =
          sources_by_source
          |> Map.get(source_key, [])
          |> Enum.filter(&(&1.sequence > first_occurrence_sequence))

        {entries, unresolved} = associate_identity(matching_occurrences, matching_sources)

        {merge_associations(entries, associations), unresolved_count + unresolved}
      end)

    by_turn =
      Map.new(by_turn, fn {turn_id, entries} ->
        {turn_id, Enum.sort_by(entries, fn {source, _ambiguous?} -> source.sequence end)}
      end)

    %{by_turn: by_turn, unresolved_count: unresolved_count}
  end

  # Each retained tool-call occurrence and evaluation-source record is one side
  # of the certification relation. For equal counts, chronological order gives
  # a canonical one-to-one assignment. Adjacent pairs can exchange producers
  # exactly when the earlier source follows the later response; those exchanges
  # form ambiguity components. This is the Ferrers-graph matching test in
  # O(n log n), without materializing every possible edge.
  defp associate_identity(occurrences, sources) when length(occurrences) == length(sources) do
    occurrences = Enum.sort_by(occurrences, & &1.sequence)
    sources = Enum.sort_by(sources, & &1.sequence)

    if Enum.zip_with(occurrences, sources, &(&2.sequence > &1.sequence)) |> Enum.all?() do
      {exact_entries(occurrences, sources), 0}
    else
      ambiguous_fallback(occurrences, sources)
    end
  end

  defp associate_identity(occurrences, sources) do
    ambiguous_fallback(occurrences, sources)
  end

  defp exact_entries(occurrences, sources) do
    max_eligible_indices = max_eligible_indices(occurrences, sources)
    same_turn_run_ends = same_turn_run_ends(occurrences)

    occurrences
    |> Enum.zip(sources)
    |> Enum.zip(max_eligible_indices)
    |> Enum.with_index()
    |> Enum.reduce({[], 0, nil}, fn {{{occurrence, source}, max_index}, index},
                                    {entries, component_start, previous_source} ->
      component_start =
        if previous_source && previous_source.sequence > occurrence.sequence,
          do: component_start,
          else: index

      ambiguous? = max_index > Map.fetch!(same_turn_run_ends, component_start)
      entry = {occurrence.turn_id, source, ambiguous?}
      {[entry | entries], component_start, source}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp max_eligible_indices(occurrences, sources) do
    indexed_occurrences = Enum.with_index(occurrences)

    sources
    |> Enum.map_reduce({indexed_occurrences, -1}, fn source, cursor ->
      {max_index, cursor} = max_eligible_index(cursor, source.sequence)
      {max_index, cursor}
    end)
    |> elem(0)
  end

  defp max_eligible_index({[{occurrence, index} | rest], _latest}, source_sequence)
       when source_sequence > occurrence.sequence,
       do: max_eligible_index({rest, index}, source_sequence)

  defp max_eligible_index(cursor, _source_sequence), do: {elem(cursor, 1), cursor}

  defp same_turn_run_ends(occurrences) do
    occurrences
    |> Enum.with_index()
    |> Enum.chunk_by(fn {occurrence, _index} -> occurrence.turn_id end)
    |> Enum.reduce(%{}, fn run, ends ->
      {_occurrence, last_index} = List.last(run)
      Enum.reduce(run, ends, fn {_occurrence, index}, acc -> Map.put(acc, index, last_index) end)
    end)
  end

  defp ambiguous_fallback(occurrences, sources) do
    occurrences = Enum.sort_by(occurrences, & &1.sequence)

    {entries, _cursor} =
      sources
      |> Enum.sort_by(& &1.sequence)
      |> Enum.map_reduce({occurrences, nil}, fn source, cursor ->
        {latest, cursor} = preceding_occurrence(cursor, source.sequence)
        entry = if latest, do: {latest.turn_id, source, true}
        {entry, cursor}
      end)

    entries = Enum.reject(entries, &is_nil/1)

    unresolved_count = length(sources) - length(entries)
    {entries, unresolved_count}
  end

  defp preceding_occurrence({[occurrence | rest], _latest}, source_sequence)
       when source_sequence > occurrence.sequence,
       do: preceding_occurrence({rest, occurrence}, source_sequence)

  defp preceding_occurrence(cursor, _source_sequence), do: {elem(cursor, 1), cursor}

  defp merge_associations(entries, associations) do
    Enum.reduce(entries, associations, fn {turn_id, source, ambiguous?}, acc ->
      Map.update(acc, turn_id, [{source, ambiguous?}], &[{source, ambiguous?} | &1])
    end)
  end
end
