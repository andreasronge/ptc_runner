defmodule PtcRunner.Kernel.RunCatalogQuery do
  @moduledoc """
  Bounded paging and filtering over one frozen private run-catalog generation.

  The query receives rows already detached and classified by
  `PtcRunner.Kernel.RunCatalogSnapshot`. It never lists a root, opens an
  artifact, or reads evidence. Cursors bind both that generation's digest and
  the complete filter query; `limit` remains a page-size choice and may change
  between pages.
  """

  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.QueryCursor
  alias PtcRunner.Kernel.QueryValidation
  alias PtcRunner.Kernel.ResultLimit

  @default_limit 20
  @max_limit 100
  @max_cursor_bytes 1_024
  @max_string_bytes 4_096
  @exact_filters ~w(run_id trace_id status name model provider correlation state)
  @allowed ~w(run_id trace_id status name model provider correlation state tags from to limit cursor)

  @spec run([map()], map(), map(), pos_integer()) :: {:ok, map()} | {:error, atom()}
  def run(rows, info, arguments, max_result_bytes)
      when is_list(rows) and is_map(info) and is_map(arguments) and
             is_integer(max_result_bytes) and max_result_bytes > 0 do
    with {:ok, catalog_digest, excluded_files} <- generation_info(info),
         :ok <- validate_keys(arguments),
         :ok <- validate_filters(arguments),
         {:ok, page} <- page_options(arguments, catalog_digest) do
      rows
      |> Enum.filter(&matches?(&1, arguments))
      |> paginate(page, catalog_digest, excluded_files, max_result_bytes)
    end
  end

  def run(_rows, _info, _arguments, _max_result_bytes), do: {:error, :invalid_query}

  defp generation_info(%{catalog_digest: digest, excluded_files: excluded_files})
       when is_binary(digest) and is_integer(excluded_files) and excluded_files >= 0,
       do: {:ok, digest, excluded_files}

  defp generation_info(_info), do: {:error, :catalog_unavailable}

  defp validate_keys(arguments) do
    if JSONValue.map?(arguments) and Map.keys(arguments) -- @allowed == [],
      do: :ok,
      else: {:error, :invalid_query}
  end

  defp validate_filters(arguments) do
    with :ok <- optional_strings(arguments, @exact_filters ++ ~w(from to)),
         :ok <- valid_optional(arguments, "tags", &valid_tags/1),
         :ok <- valid_optional(arguments, "from", &valid_timestamp/1),
         :ok <- valid_optional(arguments, "to", &valid_timestamp/1),
         do: valid_optional(arguments, "cursor", &valid_cursor/1)
  end

  defp page_options(arguments, catalog_digest) do
    filters = Map.drop(arguments, ["cursor", "limit"])

    QueryCursor.page_options(
      arguments,
      catalog_digest,
      {:catalog, filters},
      @default_limit,
      @max_limit,
      @max_cursor_bytes
    )
  end

  defp matches?(row, arguments) do
    Enum.all?(@exact_filters, &exact_match?(row, arguments, &1)) and
      tags_match?(row["tags"], arguments["tags"]) and
      after_or_equal?(row["start_timestamp"], arguments["from"]) and
      before_or_equal?(row["start_timestamp"], arguments["to"])
  end

  defp exact_match?(_row, arguments, key) when not is_map_key(arguments, key), do: true
  defp exact_match?(row, arguments, key), do: row[key] == arguments[key]

  defp tags_match?(_tags, nil), do: true

  defp tags_match?(tags, expected) when is_map(tags),
    do: Enum.all?(expected, fn {key, value} -> tags[key] == value end)

  defp tags_match?(_tags, _expected), do: false

  defp after_or_equal?(_timestamp, nil), do: true
  defp after_or_equal?(nil, _from), do: false
  defp after_or_equal?(timestamp, from), do: compare_timestamp(timestamp, from) != :lt
  defp before_or_equal?(_timestamp, nil), do: true
  defp before_or_equal?(nil, _to), do: false
  defp before_or_equal?(timestamp, to), do: compare_timestamp(timestamp, to) != :gt

  defp compare_timestamp(left, right) do
    {:ok, left_at, 0} = DateTime.from_iso8601(left)
    {:ok, right_at, 0} = DateTime.from_iso8601(right)
    DateTime.compare(left_at, right_at)
  end

  defp paginate(items, page, catalog_digest, excluded_files, max_result_bytes) do
    selected = items |> Enum.drop(page.offset) |> Enum.take(page.limit)
    context = {items, page, catalog_digest, excluded_files, max_result_bytes}
    full = page_result(selected, context)

    cond do
      ResultLimit.within?(full, max_result_bytes) ->
        {:ok, full}

      selected == [] ->
        {:error, :result_limit_exceeded}

      true ->
        fit_prefix(selected, context, 1, length(selected) - 1, nil)
    end
  end

  defp fit_prefix(_selected, _context, lower, upper, best) when lower > upper do
    if best, do: {:ok, best}, else: {:error, :result_limit_exceeded}
  end

  defp fit_prefix(selected, context, lower, upper, best) do
    count = div(lower + upper, 2)
    result = page_result(Enum.take(selected, count), context)

    if ResultLimit.within?(result, elem(context, 4)) do
      fit_prefix(selected, context, count + 1, upper, result)
    else
      fit_prefix(selected, context, lower, count - 1, best)
    end
  end

  defp page_result(
         selected,
         {all_items, %{offset: offset, query_id: query_id}, catalog_digest, excluded_files,
          _max_result_bytes}
       ) do
    next_offset = offset + length(selected)
    more? = next_offset < length(all_items)

    %{
      "items" => selected,
      "next_cursor" =>
        if(more?, do: QueryCursor.encode(next_offset, catalog_digest, query_id), else: nil),
      "truncated" => more?,
      "omitted_count" => max(length(all_items) - next_offset, 0),
      "catalog_digest" => catalog_digest,
      "excluded_files" => excluded_files
    }
  end

  defp optional_strings(arguments, keys) do
    if Enum.all?(keys, fn key ->
         not Map.has_key?(arguments, key) or valid_string(arguments[key]) == :ok
       end),
       do: :ok,
       else: {:error, :invalid_query}
  end

  defp valid_optional(arguments, key, validator) do
    if Map.has_key?(arguments, key), do: validator.(arguments[key]), else: :ok
  end

  defp valid_string(value), do: QueryValidation.string(value, @max_string_bytes)
  defp valid_tags(tags), do: QueryValidation.tags(tags, @max_string_bytes)
  defp valid_timestamp(timestamp), do: QueryValidation.timestamp(timestamp)

  defp valid_cursor(cursor), do: QueryValidation.string(cursor, @max_cursor_bytes)
end
