defmodule PtcRunner.SubAgent.Loop.NativePreview do
  @moduledoc """
  Build LLM-facing native tool result previews for combined-mode agents.

  Tier 2b of `Plans/text-mode-ptc-compute-tool.md`. When a tool is
  configured `expose: :both, cache: true`, the runtime stores the full
  result in `state.tool_cache` and returns a *preview* to the LLM. This
  module is the pure builder for that preview map.

  Three preview shapes are supported, selected by the tool's
  `native_result:` option:

    * `preview: :metadata` (default / `nil`) — schema + sample keys + count.
    * `preview: :rows`     — verbatim row sample capped at `limit:`.
    * `preview: <fun/1>`   — custom builder receiving `full_result` only.

  All three shapes are merged with the universal cache fields
  (`status: "ok"`, `full_result_cached: true`, `cache_hint: "<...>"`)
  before being returned. A custom-preview builder that raises, returns a
  non-map, or returns a non-`Jason.encode!`-able value falls back to the
  metadata preview and emits a `Logger.warning/1` tagged with the tool
  name and failure category.

  See the plan doc's "Native Tool Result Preview" → "Default Metadata
  Preview — Inference Rules" table for the exact metadata shape; this
  module is the canonical implementation of that table.

  Used by `PtcRunner.SubAgent.Loop.TextMode` in combined mode.
  """

  require Logger

  alias PtcRunner.Lisp.Formatter
  alias PtcRunner.SubAgent.KeyNormalizer
  alias PtcRunner.Temporal
  alias PtcRunner.Tool

  # Known limitations deferred from v1 (will be surfaced in Tier 4 docs):
  #
  #   * `false` values in metadata previews collapse to "null" via
  #     `||` short-circuit at `metadata_preview/1` and `list_of_maps_preview/2`
  #     (the `Map.get(result, k) || fetch_by_atom(...)` pattern). A boolean
  #     `false` value triggers the fallback path. Fix requires a
  #     three-arg `Map.get/3` with a sentinel default; deferred for
  #     scope discipline.
  #   * Atom + string key collision in the same map silently overwrites
  #     during `to_string/1` normalization in `metadata_preview/1`.
  #   * `-0.0` collapses to integer `0` via the cache-key path
  #     (`canonical_cache_key/2`); harmless for cache identity but
  #     diverges from JSON's strict equality.
  #   * NaN / Infinity floats: BEAM doesn't produce them from arithmetic,
  #     but a foreign-source NIF could. They pass through unchanged in
  #     the cache path; preview path may JSON-fail.
  #   * Charlist (`[97, 98, 99]`) vs binary (`"abc"`) cache identity is
  #     not unified — they hash to different keys.
  #   * Decimal/DateTime values inside *cache key* args are not fully
  #     canonicalized (the Tier 3.5 Fix 6 only addresses preview rows);
  #     they reach `canonicalize/1`'s catch-all clause and pass through
  #     unchanged.

  @type preview_status :: :ok | :fallback

  @max_properties 20
  @default_row_limit 20

  @doc """
  Build a preview map for `full_result` per `tool.native_result`.

  Returns `{:ok, preview}` for the default-success path or
  `{:fallback, preview}` when a custom preview builder failed and the
  metadata preview was used as a recovery. Both shapes are
  Jason-encodable and carry the universal cache fields
  (`status`, `full_result_cached`, `cache_hint`).

  `args` is the *canonical* args map (post-`KeyNormalizer` normalization)
  used to render the `cache_hint`'s `(tool/<name> <ARGS_FRAGMENT>)`
  example. Pass the raw args; the helper canonicalizes internally.
  """
  @spec build(Tool.t(), term(), map()) :: {preview_status(), map()}
  def build(%Tool{} = tool, full_result, args) when is_map(args) do
    cache_fields = cache_fields(tool, args)

    case preview_kind(tool) do
      :metadata ->
        {:ok, Map.merge(metadata_preview(full_result), cache_fields)}

      {:rows, limit} ->
        {:ok, Map.merge(rows_preview(full_result, limit), cache_fields)}

      {:custom, fun} ->
        run_custom(tool.name, fun, full_result, cache_fields)
    end
  end

  @doc """
  Render the `cache_hint` string for a native preview.

  Format:

      Call ptc_lisp_execute and then call (tool/<name> <ARGS>) to
      process the full cached result.

  `<ARGS>` is produced by `PtcRunner.Lisp.Formatter.format/1` after
  converting the canonical args map to PTC-Lisp AST per the conversion
  table in Addendum #26 of the plan. Strings, nested maps, vectors, and
  keyword keys all round-trip through Formatter — no hand-rolled
  escaping in this module.
  """
  @spec cache_hint(String.t(), map()) :: String.t()
  def cache_hint(tool_name, args) when is_binary(tool_name) and is_map(args) do
    {_name, canonical_args} = KeyNormalizer.canonical_cache_key(tool_name, args)
    args_fragment = Formatter.format(to_ast(canonical_args))

    "Call ptc_lisp_execute and then call " <>
      "(tool/#{tool_name} #{args_fragment}) " <>
      "to process the full cached result."
  end

  # ---------------------------------------------------------------------------
  # Preview kind dispatch
  # ---------------------------------------------------------------------------

  defp preview_kind(%Tool{native_result: nil}), do: :metadata

  defp preview_kind(%Tool{native_result: opts}) when is_list(opts) do
    case Keyword.get(opts, :preview, :metadata) do
      :metadata ->
        :metadata

      :rows ->
        {:rows, Keyword.get(opts, :limit, @default_row_limit)}

      fun when is_function(fun, 1) ->
        {:custom, fun}

      _other ->
        # Validator should reject this at construction; defensive fallback.
        :metadata
    end
  end

  # ---------------------------------------------------------------------------
  # Default metadata preview
  # ---------------------------------------------------------------------------

  defp metadata_preview(result) when is_list(result) do
    case result do
      [] ->
        %{"result_count" => 0, "schema" => %{"type" => "array", "items" => %{}}}

      [first | _] = list when is_map(first) and not is_struct(first) ->
        list_of_maps_preview(list, length(list))

      list ->
        list_of_scalars_preview(list, length(list))
    end
  end

  defp metadata_preview(result) when is_map(result) and not is_struct(result) do
    case map_size(result) do
      0 ->
        %{"schema" => %{"type" => "object"}, "sample_keys" => []}

      _ ->
        keys = result |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
        {properties, truncated?} = take_truncated(keys, @max_properties)

        properties_map =
          Map.new(properties, fn k ->
            {k, json_type_for(Map.get(result, k) || fetch_by_atom(result, k))}
          end)

        schema =
          %{"type" => "object", "properties" => properties_map}
          |> maybe_truncated(truncated?)

        %{"schema" => schema, "sample_keys" => properties}
    end
  end

  defp metadata_preview(result) do
    %{"schema" => %{"type" => json_type_for(result)}}
  end

  defp list_of_maps_preview([first | _] = list, count) do
    if consistent_keys?(list) do
      keys = first |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
      {properties, truncated?} = take_truncated(keys, @max_properties)

      properties_map =
        Map.new(properties, fn k ->
          {k, json_type_for(Map.get(first, k) || fetch_by_atom(first, k))}
        end)

      items =
        %{"type" => "object", "properties" => properties_map}
        |> maybe_truncated(truncated?)

      %{
        "result_count" => count,
        "schema" => %{"type" => "array", "items" => items},
        "sample_keys" => properties
      }
    else
      %{
        "result_count" => count,
        "schema" => %{"type" => "array", "items" => %{"type" => "object"}}
      }
    end
  end

  defp list_of_scalars_preview([first | _] = list, count) do
    item_type =
      if Enum.all?(list, &(json_type_for(&1) == json_type_for(first))) do
        json_type_for(first)
      else
        "any"
      end

    %{
      "result_count" => count,
      "schema" => %{"type" => "array", "items" => %{"type" => item_type}}
    }
  end

  # Addendum #5 — first key set vs the next 4 elements that exist.
  defp consistent_keys?([_only]), do: true

  defp consistent_keys?([first | rest]) when is_map(first) do
    first_keys = first |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()

    rest
    |> Enum.take(4)
    |> Enum.all?(fn item ->
      is_map(item) and not is_struct(item) and
        item |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new() == first_keys
    end)
  end

  defp consistent_keys?(_), do: false

  defp take_truncated(items, max) do
    if length(items) > max do
      {Enum.take(items, max), true}
    else
      {items, false}
    end
  end

  defp maybe_truncated(map, false), do: map
  defp maybe_truncated(map, true), do: Map.put(map, "truncated", true)

  # JSON-Schema-ish type names per the plan's Default Metadata Preview rules.
  defp json_type_for(value) when is_integer(value), do: "integer"
  defp json_type_for(value) when is_float(value), do: "number"
  defp json_type_for(value) when is_binary(value), do: "string"
  defp json_type_for(value) when is_boolean(value), do: "boolean"
  defp json_type_for(nil), do: "null"
  defp json_type_for(value) when is_list(value), do: "array"
  defp json_type_for(value) when is_map(value) and not is_struct(value), do: "object"
  defp json_type_for(_), do: "string"

  # Maps may have either string or atom keys (Elixir literal syntax). The
  # property list is stringified, but lookups need to find both forms.
  defp fetch_by_atom(map, key) when is_binary(key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp fetch_by_atom(_, _), do: nil

  # ---------------------------------------------------------------------------
  # :rows preview
  # ---------------------------------------------------------------------------

  defp rows_preview(result, limit) when is_list(result) do
    # Tier 3.5 Fix 6: normalize temporal structs (DateTime, Date, Time,
    # NaiveDateTime) to ISO 8601 strings before they enter the preview
    # map. Those structs have no Jason encoder and would otherwise crash
    # the preview builder when `Jason.encode!/1` runs in
    # `Loop.TextMode.run_and_cache/6`. Same treatment as the legacy
    # tool-result encoding path.
    raw_rows = Enum.take(result, limit)
    rows = Temporal.walk(raw_rows)
    count = length(result)

    schema =
      case rows do
        [] -> %{"type" => "array", "items" => %{}}
        [first | _] = sample -> rows_schema(sample, first)
      end

    sample_keys =
      case rows do
        [first | _] when is_map(first) and not is_struct(first) ->
          if consistent_keys?(rows) do
            first |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
          else
            nil
          end

        _ ->
          nil
      end

    base = %{
      "result_count" => count,
      "schema" => schema,
      "rows" => rows
    }

    if sample_keys, do: Map.put(base, "sample_keys", sample_keys), else: base
  end

  defp rows_preview(result, _limit) do
    # Non-list results: degrade to metadata semantics for safety.
    metadata_preview(result)
  end

  defp rows_schema(sample, first) when is_map(first) and not is_struct(first) do
    if consistent_keys?(sample) do
      keys = first |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
      {properties, truncated?} = take_truncated(keys, @max_properties)

      properties_map =
        Map.new(properties, fn k ->
          {k, json_type_for(Map.get(first, k) || fetch_by_atom(first, k))}
        end)

      items =
        %{"type" => "object", "properties" => properties_map}
        |> maybe_truncated(truncated?)

      %{"type" => "array", "items" => items}
    else
      %{"type" => "array", "items" => %{"type" => "object"}}
    end
  end

  defp rows_schema(sample, first) do
    item_type =
      if Enum.all?(sample, &(json_type_for(&1) == json_type_for(first))) do
        json_type_for(first)
      else
        "any"
      end

    %{"type" => "array", "items" => %{"type" => item_type}}
  end

  # ---------------------------------------------------------------------------
  # Custom preview function
  # ---------------------------------------------------------------------------

  defp run_custom(tool_name, fun, full_result, cache_fields) do
    raw =
      try do
        {:ok, fun.(full_result)}
      rescue
        e -> {:raised, e}
      end

    case raw do
      {:ok, value} when is_map(value) ->
        merged = Map.merge(stringify_keys(value), cache_fields)

        case Jason.encode(merged) do
          {:ok, _json} ->
            {:ok, merged}

          {:error, _} ->
            warn_fallback(tool_name, :non_encodable)
            {:fallback, Map.merge(metadata_preview(full_result), cache_fields)}
        end

      {:ok, _other} ->
        warn_fallback(tool_name, :non_map)
        {:fallback, Map.merge(metadata_preview(full_result), cache_fields)}

      {:raised, _e} ->
        warn_fallback(tool_name, :raised)
        {:fallback, Map.merge(metadata_preview(full_result), cache_fields)}
    end
  end

  defp warn_fallback(tool_name, category) do
    Logger.warning(
      "[ptc_runner] custom native_result preview for tool #{inspect(tool_name)} " <>
        "fell back to metadata: category=#{category}"
    )
  end

  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string_key(k), v} end)
  end

  defp to_string_key(k) when is_binary(k), do: k
  defp to_string_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_string_key(k), do: k

  # ---------------------------------------------------------------------------
  # Cache fields (universal — merged into every preview shape)
  # ---------------------------------------------------------------------------

  defp cache_fields(%Tool{name: name}, args) do
    %{
      "status" => "ok",
      "full_result_cached" => true,
      "cache_hint" => cache_hint(name, args)
    }
  end

  # ---------------------------------------------------------------------------
  # PTC-Lisp AST conversion for cache_hint (Addendum #26)
  # ---------------------------------------------------------------------------

  # Top-level: the canonicalized args map → `{:map, [...]}` AST so
  # Formatter renders Clojure-style `{:k "v"}`.
  defp to_ast(map) when is_map(map) and not is_struct(map) do
    pairs =
      map
      # canonical_cache_key/2 already stringified keys; sort here for
      # deterministic rendering (sorted-by-string-key per Addendum #26).
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> {ast_key(k), to_ast(v)} end)

    {:map, pairs}
  end

  defp to_ast(list) when is_list(list) do
    {:vector, Enum.map(list, &to_ast/1)}
  end

  defp to_ast(tuple) when is_tuple(tuple) do
    # Tuples (rare in canonical args, but possible from PTC-Lisp paths)
    # flatten to vector form so the LLM gets a stable Clojure surface.
    {:vector, tuple |> Tuple.to_list() |> Enum.map(&to_ast/1)}
  end

  defp to_ast(value) when is_binary(value), do: {:string, value}

  defp to_ast(value) when is_atom(value) and value not in [nil, true, false] do
    # Atom values in canonical args are unusual but legal; render as
    # keywords so they round-trip through PTC-Lisp parser.
    {:keyword, Atom.to_string(value)}
  end

  defp to_ast(value), do: value

  # Map keys: canonical_cache_key/2 produces string keys; we keep strings
  # in the AST since `Formatter.format({:keyword, k})` interpolates `k`
  # and produces the same `:foo` rendering regardless of atom-vs-string.
  defp ast_key(k) when is_binary(k), do: {:keyword, k}
  defp ast_key(k) when is_atom(k), do: {:keyword, Atom.to_string(k)}
  defp ast_key(k), do: {:keyword, to_string(k)}
end
