defmodule PtcRunner.Research.SealedEvidenceLog.Oracle do
  @moduledoc """
  Differential comparison against `InspectionQuery.compile/3` and `query/6`.

  Pages are compared on item shape, order, errors, counts, truncation, and
  page-by-page `omitted_count`. Snapshot-hash values and opaque cursor bytes
  are ignored; each implementation is walked with its own cursors.
  """

  alias PtcRunner.Kernel.InspectionQuery
  alias PtcRunner.Research.SealedEvidenceLog

  @ignore ~w(snapshot_hash next_cursor)

  @spec compile_current([[map()]], binary(), map()) ::
          {:ok, %{source_id: binary(), collections: map()}} | {:error, atom()}
  def compile_current(artifacts, trace_source_id, trace_analysis) do
    InspectionQuery.compile(artifacts, trace_source_id, trace_analysis)
  end

  @spec query_current(map(), binary(), atom(), map(), pos_integer()) ::
          {:ok, map()} | {:error, atom()}
  def query_current(collections, source_id, operation, arguments, max_result_bytes) do
    InspectionQuery.query(collections, source_id, operation, arguments, max_result_bytes)
  end

  @spec walk_equal(map(), SealedEvidenceLog.Snapshot.t(), atom(), map(), pos_integer()) ::
          :ok | {:error, map()}
  def walk_equal(current, snapshot, operation, arguments, max_result_bytes) do
    base = Map.delete(arguments, "cursor")
    compare_step(current, snapshot, operation, base, nil, nil, max_result_bytes, 0)
  end

  @spec comparable(map() | {:error, atom()}) :: map() | {:error, atom()}
  def comparable({:error, reason}), do: {:error, reason}

  def comparable(page) when is_map(page) do
    page
    |> Map.drop(@ignore)
    |> maybe_items()
  end

  defp compare_step(_current, _snapshot, _operation, _base, _cc, _pc, _max_bytes, pages)
       when pages > 64,
       do: {:error, %{reason: :too_many_pages}}

  defp compare_step(
         current,
         snapshot,
         operation,
         base,
         current_cursor,
         proto_cursor,
         max_bytes,
         pages
       ) do
    current_result =
      query_current(
        current.collections,
        current.source_id,
        operation,
        put_cursor(base, current_cursor),
        max_bytes
      )

    proto_result = proto_query(snapshot, operation, put_cursor(base, proto_cursor), max_bytes)

    with :ok <- compare_results(current_result, proto_result, operation) do
      advance(
        current,
        snapshot,
        operation,
        base,
        current_result,
        proto_result,
        max_bytes,
        pages
      )
    end
  end

  defp advance(
         current,
         snapshot,
         operation,
         base,
         {:ok, current_page},
         {:ok, proto_page},
         max_bytes,
         pages
       ) do
    cond do
      not Map.has_key?(current_page, "truncated") ->
        :ok

      current_page["truncated"] != true and proto_page["truncated"] != true ->
        :ok

      current_page["truncated"] != proto_page["truncated"] ->
        {:error, %{reason: :truncation_mismatch}}

      true ->
        compare_step(
          current,
          snapshot,
          operation,
          base,
          current_page["next_cursor"],
          proto_page["next_cursor"],
          max_bytes,
          pages + 1
        )
    end
  end

  defp advance(
         _current,
         _snapshot,
         _operation,
         _base,
         _current_result,
         _proto_result,
         _max,
         _pages
       ),
       do: :ok

  defp put_cursor(base, nil), do: base
  defp put_cursor(base, cursor), do: Map.put(base, "cursor", cursor)

  defp proto_query(snapshot, operation, arguments, max_bytes) do
    case SealedEvidenceLog.query(snapshot, operation, arguments, max_result_bytes: max_bytes) do
      {:ok, page, _metrics} -> {:ok, page}
      {:error, reason} -> {:error, reason}
    end
  end

  defp compare_results({:error, reason}, {:error, reason}, _operation), do: :ok

  defp compare_results({:ok, left}, {:ok, right}, _operation) do
    left = comparable(left)
    right = comparable(right)
    if left == right, do: :ok, else: {:error, %{current: left, prototype: right}}
  end

  defp compare_results(left, right, operation),
    do: {:error, %{operation: operation, current: left, prototype: right}}

  defp maybe_items(%{"items" => items} = page),
    do: Map.put(page, "items", Enum.map(items, &comparable_item/1))

  defp maybe_items(page), do: page

  defp comparable_item(item) when is_map(item), do: item
end
