defmodule PtcRunner.Lisp.Runtime.Describe do
  @moduledoc """
  Bounded data-shape summaries for PTC-Lisp values.
  """

  alias PtcRunner.Lisp.Env.Builtin
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.Keyword, as: LispKeyword

  @default_depth 1
  @max_depth 5
  @max_root_items 1_000
  @max_map_keys 100
  @max_paths 300
  @max_path_values 10_000
  @max_examples 3
  @max_example_chars 120
  @distinct_cap 50
  @numeric_string_max_chars 64

  @type opts :: %{
          depth: pos_integer(),
          paths: boolean(),
          sample: pos_integer()
        }

  @spec describe(term()) :: map()
  def describe(value), do: describe(value, %{})

  @spec describe(term(), term()) :: map()
  def describe(value, raw_opts) do
    opts = normalize_opts(raw_opts)

    value
    |> root_summary(opts)
    |> maybe_add_paths(value, opts)
  end

  defp normalize_opts(raw_opts) when is_map(raw_opts) do
    depth =
      raw_opts
      |> option(:depth, @default_depth)
      |> bounded_int(@default_depth, 1, @max_depth)

    sample =
      raw_opts
      |> option(:sample, @max_examples)
      |> bounded_int(@max_examples, 1, @max_examples)

    %{depth: depth, paths: truthy?(option(raw_opts, :paths, false)), sample: sample}
  end

  defp normalize_opts(_), do: normalize_opts(%{})

  defp option(map, key, default) do
    string_key = Atom.to_string(key)

    Map.get(
      map,
      key,
      Map.get(map, string_key, Map.get(map, LispKeyword.new(string_key), default))
    )
  end

  defp bounded_int(value, _default, min, max) when is_integer(value) do
    value |> Kernel.max(min) |> Kernel.min(max)
  end

  defp bounded_int(_, default, _min, _max), do: default

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true

  defp root_summary(value, opts) when is_map(value) and not is_struct(value) do
    {entries, caps} = map_entries(value)

    %{
      type: "map",
      count: map_size(value),
      key_types: key_type_histogram(entries),
      keys: summarize_map_keys(entries, opts, false, max(map_size(value), 1))
    }
    |> put_caps(caps)
  end

  defp root_summary(value, opts) when is_list(value) do
    {items, caps, count_capped?} = take_root_items(value)
    map_items = Enum.filter(items, &(type_name(&1) == "map"))

    base =
      %{
        type: "vector",
        count: length(items),
        scanned: length(items),
        item_types: histogram_by(items, &type_name/1)
      }
      |> put_if(:count_capped, true, fn _ -> count_capped? end)

    base =
      if map_items == [] do
        base
      else
        {entries, key_caps} = collection_map_entries(map_items)

        base
        |> Map.put(:key_types, histogram_by(Enum.map(entries, &elem(&1, 1)), &type_name/1))
        |> Map.put(:keys, summarize_collection_map_keys(entries, opts, length(items)))
        |> put_caps(key_caps)
      end

    put_caps(base, caps)
  end

  defp root_summary(%MapSet{} = set, _opts) do
    items = Enum.take(set, @max_root_items)

    %{
      type: "set",
      count: MapSet.size(set),
      scanned: min(MapSet.size(set), @max_root_items),
      item_types: histogram_by(items, &type_name/1)
    }
    |> put_caps(if(MapSet.size(set) > @max_root_items, do: ["max_items"], else: []))
  end

  defp root_summary(value, opts) do
    field_summary([value], opts)
    |> Map.merge(%{type: type_name(value), sample: example_value(value)})
  end

  defp take_root_items(items) do
    sampled = Enum.take(items, @max_root_items + 1)
    count_capped? = length(sampled) > @max_root_items
    taken = Enum.take(sampled, @max_root_items)
    caps = if count_capped?, do: ["max_items"], else: []
    {taken, caps, count_capped?}
  end

  defp map_entries(map) do
    entries = bounded_sorted_map_entries(map)

    caps = if map_size(map) > @max_map_keys, do: ["max_keys"], else: []
    {entries, caps}
  end

  defp bounded_sorted_map_entries(map) do
    Enum.reduce(map, [], fn entry, entries ->
      entry
      |> insert_sorted_map_entry(entries)
      |> Enum.take(@max_map_keys)
    end)
  end

  defp insert_sorted_map_entry(entry, entries) do
    sort_key = map_entry_sort_key(entry)

    {before, after_entries} =
      Enum.split_while(entries, fn existing ->
        map_entry_sort_key(existing) <= sort_key
      end)

    before ++ [entry | after_entries]
  end

  defp map_entry_sort_key({key, _value}) do
    {render_key(key), type_name(key), key_hash(key)}
  end

  defp collection_map_entries(maps) do
    maps
    |> Enum.with_index()
    |> Enum.reduce({[], [], MapSet.new()}, fn {map, index}, {entries_acc, caps_acc, seen_keys} ->
      {entries, caps} = map_entries(map)
      {kept, seen_keys, collection_caps} = take_collection_key_entries(entries, index, seen_keys)
      {kept ++ entries_acc, caps_acc ++ caps ++ collection_caps, seen_keys}
    end)
    |> then(fn {entries, caps, _seen_keys} -> {entries, caps} end)
  end

  defp take_collection_key_entries(entries, index, seen_keys) do
    Enum.reduce(entries, {[], seen_keys, []}, fn {key, value},
                                                 {entries_acc, seen_keys, caps_acc} ->
      identity = key_identity(key)

      cond do
        MapSet.member?(seen_keys, identity) ->
          {[{index, key, value} | entries_acc], seen_keys, caps_acc}

        MapSet.size(seen_keys) < @max_map_keys ->
          {[{index, key, value} | entries_acc], MapSet.put(seen_keys, identity), caps_acc}

        true ->
          {entries_acc, seen_keys, ["max_keys" | caps_acc]}
      end
    end)
    |> then(fn {entries_acc, seen_keys, caps_acc} ->
      {Enum.reverse(entries_acc), seen_keys, caps_acc}
    end)
  end

  defp summarize_map_keys(entries, opts, include_presence?, denominator) do
    collisions = key_collisions(entries, fn {key, _value} -> key end)

    entries
    |> Enum.map(fn {key, value} ->
      summary = field_summary([value], opts)
      summary = maybe_put_presence(summary, include_presence?, 1, denominator)
      {render_summary_key(key, collisions), summary}
    end)
    |> Map.new()
  end

  defp summarize_collection_map_keys(entries, opts, denominator) do
    collisions = key_collisions(entries, fn {_index, key, _value} -> key end)

    entries
    |> Enum.group_by(
      fn {_index, key, _value} -> render_summary_key(key, collisions) end,
      fn {index, _key, value} -> {index, value} end
    )
    |> Enum.map(fn {key, indexed_values} ->
      values = Enum.map(indexed_values, &elem(&1, 1))
      present = indexed_values |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()

      summary =
        values
        |> field_summary(opts)
        |> maybe_put_presence(true, present, denominator)

      {key, summary}
    end)
    |> Enum.sort_by(fn {key, _summary} -> key end)
    |> Map.new()
  end

  defp maybe_put_presence(summary, false, _present, _denominator), do: summary

  defp maybe_put_presence(summary, true, present, denominator) do
    summary
    |> Map.put(:present, present)
    |> Map.put(:pct, pct(present, denominator))
  end

  defp field_summary(values, opts) do
    values = Enum.to_list(values)

    %{
      types: histogram_by(values, &type_name/1),
      examples: examples(values, opts.sample)
    }
    |> put_non_empty(values)
    |> put_range(values)
    |> put_distinct(values)
  end

  defp examples(values, limit) do
    values
    |> Enum.reduce([], fn value, acc ->
      if length(acc) >= limit or Enum.any?(acc, &(example_key(&1) == example_key(value))) do
        acc
      else
        acc ++ [example_value(value)]
      end
    end)
  end

  defp example_value(value) when is_binary(value), do: truncate_string(value, @max_example_chars)

  defp example_value(value)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_atom(value) do
    value
  end

  defp example_value(%LispKeyword{} = value), do: value

  defp example_value(value) do
    value
    |> Format.to_clojure(printable_limit: @max_example_chars)
    |> elem(0)
    |> truncate_string(@max_example_chars)
  end

  defp example_key(value) do
    value
    |> Format.to_clojure(printable_limit: @max_example_chars)
    |> elem(0)
  end

  # `non_empty: 0` is the absence signal this profiler exists to surface, so
  # the field is emitted whenever the values are countable at all — only
  # fields with no countable values (e.g. all integers) omit it.
  defp put_non_empty(summary, values) do
    if Enum.any?(values, &countable?/1) do
      Map.put(summary, :non_empty, non_empty_count(values))
    else
      summary
    end
  end

  defp countable?(value) when is_binary(value) or is_list(value), do: true
  defp countable?(%MapSet{}), do: true
  defp countable?(value) when is_map(value) and not is_struct(value), do: true
  defp countable?(_), do: false

  defp non_empty_count(values) do
    Enum.count(values, fn
      value when is_binary(value) -> value != ""
      value when is_list(value) -> value != []
      %MapSet{} = value -> MapSet.size(value) > 0
      value when is_map(value) and not is_struct(value) -> map_size(value) > 0
      _ -> false
    end)
  end

  defp put_range(summary, values) do
    values
    |> Enum.flat_map(&numeric_measure/1)
    |> case do
      [] ->
        summary

      nums ->
        Map.put(summary, :range, %{min: Enum.min(nums), max: Enum.max(nums)})
    end
  end

  defp numeric_measure(value) when is_integer(value), do: [value]
  defp numeric_measure(value) when is_float(value), do: [value]

  defp numeric_measure(value) when is_binary(value) do
    if String.length(value) <= @numeric_string_max_chars do
      case Float.parse(value) do
        {num, ""} -> [num]
        _ -> []
      end
    else
      []
    end
  end

  defp numeric_measure(_), do: []

  defp put_distinct(summary, values) do
    scalar_values =
      Enum.filter(
        values,
        &(type_name(&1) in ["nil", "boolean", "integer", "float", "string", "keyword"])
      )

    if scalar_values == [] do
      summary
    else
      {distinct, capped?} = bounded_distinct(scalar_values)

      summary
      |> Map.put(:distinct_count, MapSet.size(distinct))
      |> put_if(:distinct_capped, true, fn _ -> capped? end)
    end
  end

  defp bounded_distinct(values) do
    Enum.reduce_while(values, {MapSet.new(), false}, fn value, {seen, _capped?} ->
      key = example_key(value)

      cond do
        MapSet.member?(seen, key) ->
          {:cont, {seen, false}}

        MapSet.size(seen) < @distinct_cap ->
          {:cont, {MapSet.put(seen, key), false}}

        true ->
          {:halt, {seen, true}}
      end
    end)
  end

  defp maybe_add_paths(summary, _value, %{paths: false}), do: summary

  defp maybe_add_paths(summary, value, opts) do
    {paths_by_name, caps, denominator} = path_values(value, opts.depth)

    paths =
      paths_by_name
      |> Enum.take(@max_paths)
      |> Enum.map(fn {path, path_values} ->
        values = Enum.map(path_values, &elem(&1, 1))
        present = path_values |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()

        summary =
          values
          |> field_summary(opts)
          |> maybe_put_presence(true, present, denominator)
          |> put_if(:value_count, length(values), &(&1 > present))

        {path, summary}
      end)
      |> Enum.sort_by(fn {path, _} -> path end)
      |> Map.new()

    summary
    |> Map.put(:paths, paths)
    |> put_caps(caps)
  end

  defp path_values(value, max_depth) when is_list(value) do
    {items, caps, _count_capped?} = take_root_items(value)

    {path_entries, nested_caps, state} =
      items
      |> Enum.with_index()
      |> Enum.reduce({[], [], path_state()}, fn {item, index}, {entries_acc, caps_acc, state} ->
        {entries, item_caps, state} = collect_paths(item, [], 0, max_depth, index, state, 0)
        {entries_acc ++ entries, caps_acc ++ item_caps, state}
      end)

    {group_path_values(path_entries), caps ++ nested_caps ++ path_caps(state), length(items)}
  end

  defp path_values(value, max_depth) do
    {entries, caps, state} = collect_paths(value, [], 0, max_depth, 0, path_state(), 0)

    {group_path_values(entries), caps ++ path_caps(state), 1}
  end

  defp path_state,
    do: %{seen: MapSet.new(), capped?: false, value_count: 0, values_capped?: false}

  defp path_caps(%{values_capped?: true} = state),
    do: ["max_path_values" | path_caps(%{state | values_capped?: false})]

  defp path_caps(%{capped?: true}), do: ["max_paths"]
  defp path_caps(_state), do: []

  defp collect_paths(value, prefix, depth, max_depth, root_id, state, list_depth)

  defp collect_paths(value, prefix, depth, max_depth, root_id, state, list_depth)
       when is_map(value) and not is_struct(value) and depth < max_depth do
    {entries, caps} = map_entries(value)
    collisions = key_collisions(entries, fn {key, _value} -> key end)

    {path_entries, nested_caps, state} =
      Enum.reduce(entries, {[], caps, state}, fn {key, child}, {entries_acc, caps_acc, state} ->
        path = prefix ++ [render_path_part(key, collisions)]
        path_name = Enum.join(path, ".")

        case register_path(path_name, state) do
          {:ok, state} ->
            {entry, state} = register_path_value(path_name, root_id, child, state)

            if entry == nil do
              {entries_acc, caps_acc, state}
            else
              {child_entries, child_caps, state} =
                collect_paths(child, path, depth + 1, max_depth, root_id, state, list_depth)

              {entries_acc ++ [entry | child_entries], caps_acc ++ child_caps, state}
            end

          {:capped, state} ->
            {entries_acc, caps_acc, state}
        end
      end)

    {path_entries, nested_caps, state}
  end

  defp collect_paths(value, prefix, depth, max_depth, root_id, state, list_depth)
       when is_list(value) and prefix != [] and depth < max_depth and list_depth < @max_depth do
    {items, caps, _count_capped?} = take_root_items(value)

    {path_entries, nested_caps, state} =
      Enum.reduce(items, {[], caps, state}, fn item, {entries_acc, caps_acc, state} ->
        {entries, item_caps, state} =
          collect_paths(item, prefix, depth, max_depth, root_id, state, list_depth + 1)

        {entries_acc ++ entries, caps_acc ++ item_caps, state}
      end)

    {path_entries, nested_caps, state}
  end

  defp collect_paths(value, prefix, depth, max_depth, _root_id, state, list_depth)
       when is_list(value) and prefix != [] and depth < max_depth and list_depth >= @max_depth and
              value != [] do
    {[], ["max_depth"], state}
  end

  defp collect_paths(_value, _prefix, _depth, _max_depth, _root_id, state, _list_depth),
    do: {[], [], state}

  defp register_path(path, state) do
    cond do
      MapSet.member?(state.seen, path) ->
        {:ok, state}

      MapSet.size(state.seen) < @max_paths ->
        {:ok, %{state | seen: MapSet.put(state.seen, path)}}

      true ->
        {:capped, %{state | capped?: true}}
    end
  end

  defp register_path_value(_path, _root_id, _value, %{value_count: count} = state)
       when count >= @max_path_values do
    {nil, %{state | values_capped?: true}}
  end

  defp register_path_value(path, root_id, value, state) do
    {{path, root_id, value}, %{state | value_count: state.value_count + 1}}
  end

  defp group_path_values(path_values) do
    path_values
    |> Enum.group_by(fn {path, _root_id, _value} -> path end, fn {_path, root_id, value} ->
      {root_id, value}
    end)
    |> Enum.sort_by(fn {path, _values} -> path end)
    |> Map.new()
  end

  defp histogram_by(values, fun) do
    values
    |> Enum.map(fun)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {key, _count} -> key end)
    |> Map.new()
  end

  defp key_type_histogram(entries) do
    entries
    |> Enum.map(fn {key, _value} -> type_name(key) end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {key, _count} -> key end)
    |> Map.new()
  end

  defp type_name(nil), do: "nil"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(:nan), do: "nan"
  defp type_name(:infinity), do: "infinity"
  defp type_name(:negative_infinity), do: "infinity"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "float"
  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(%LispKeyword{}), do: "keyword"
  defp type_name(value) when is_atom(value), do: "keyword"
  defp type_name(value) when is_list(value), do: "vector"
  defp type_name(%MapSet{}), do: "set"
  defp type_name(%Builtin{}), do: "function"
  defp type_name(value) when is_function(value), do: "function"
  defp type_name(value) when is_map(value), do: "map"
  defp type_name({:closure, _, _, _, _, _}), do: "function"
  defp type_name({tag, _}) when tag in [:normal, :collect], do: "function"

  defp type_name({tag, _, _})
       when tag in [:variadic, :variadic_nonempty, :multi_arity, :special],
       do: "function"

  defp type_name(_), do: "unknown"

  defp render_key(key) when is_binary(key), do: truncate_string(key, @max_example_chars)

  defp render_key(key) do
    key
    |> Format.to_clojure(printable_limit: @max_example_chars)
    |> elem(0)
  end

  defp key_collisions(entries, key_fun) do
    entries
    |> Enum.reduce(%{}, fn entry, acc ->
      key = key_fun.(entry)
      rendered = render_key(key)
      identity = key_identity(key)
      Map.update(acc, rendered, MapSet.new([identity]), &MapSet.put(&1, identity))
    end)
  end

  defp key_identity(key), do: {type_name(key), key}

  defp render_summary_key(key, collisions) do
    rendered = render_key(key)
    identities = Map.get(collisions, rendered, MapSet.new())

    if MapSet.size(identities) > 1 do
      type = type_name(key)
      base = type <> ":" <> rendered

      if same_type_collision?(identities, type) do
        base <> "#" <> key_hash(key)
      else
        base
      end
    else
      rendered
    end
  end

  defp same_type_collision?(identities, type) do
    identities
    |> Enum.count(fn {identity_type, _key} -> identity_type == type end)
    |> Kernel.>(1)
  end

  defp key_hash(key) do
    key
    |> key_hash_bytes()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  defp key_hash_bytes(key) when is_binary(key), do: key

  defp key_hash_bytes(key) do
    :erlang.term_to_binary(key)
  rescue
    _ -> inspect(key, limit: 5, printable_limit: @max_example_chars)
  end

  defp render_path_part(key, collisions) when is_binary(key) do
    key
    |> render_summary_key(collisions)
    |> escape_path_part()
  end

  defp render_path_part(key, collisions) do
    key
    |> render_summary_key(collisions)
    |> escape_path_part()
  end

  defp escape_path_part(part) do
    part
    |> String.replace("\\", "\\\\")
    |> String.replace(".", "\\.")
  end

  defp truncate_string(value, limit) do
    if String.length(value) > limit do
      String.slice(value, 0, limit) <> "...(#{String.length(value)} chars)"
    else
      value
    end
  end

  defp put_caps(summary, []), do: summary

  defp put_caps(summary, caps) do
    caps =
      summary
      |> Map.get(:caps_hit, [])
      |> Kernel.++(caps)
      |> Enum.uniq()
      |> Enum.sort()

    summary
    |> Map.put(:truncated, true)
    |> Map.put(:caps_hit, caps)
  end

  defp put_if(map, key, value, pred) do
    if pred.(value), do: Map.put(map, key, value), else: map
  end

  defp pct(_present, 0), do: 0.0
  defp pct(present, denominator), do: Float.round(present / denominator * 100.0, 1)
end
