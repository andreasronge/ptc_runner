defmodule PtcRunner.Kernel.InspectionPageCollector do
  @moduledoc false

  @limit 1_000
  @max_pages 1_000
  @max_bytes 1_000_000

  @spec collect((map() -> {:ok, map()} | {:error, atom()}), atom(), binary(), binary() | nil) ::
          {:ok, map()} | {:error, atom()}
  def collect(query, operation, run_id, snapshot_hash \\ nil)

  def collect(query, operation, run_id, snapshot_hash)
      when is_function(query, 1) and is_atom(operation) and is_binary(run_id) and
             (is_binary(snapshot_hash) or is_nil(snapshot_hash)) do
    collect(query, operation, run_id, nil, [], snapshot_hash, %{}, 0)
  end

  def collect(_query, _operation, _run_id, _snapshot_hash),
    do: {:error, :invalid_inspection_query}

  defp collect(_query, _operation, _run_id, _cursor, _items, _hash, _metadata, @max_pages),
    do: {:error, :result_limit_exceeded}

  defp collect(query, operation, run_id, cursor, items, hash, metadata, pages) do
    arguments = %{"run_id" => run_id, "limit" => @limit}
    arguments = if cursor, do: Map.put(arguments, "cursor", cursor), else: arguments

    with {:ok, %{"items" => page_items} = page} <- query.(arguments),
         true <- is_list(page_items),
         next_items = items ++ page_items,
         true <- byte_size(Jason.encode!(next_items)) <= @max_bytes do
      next_hash = hash || page["snapshot_hash"]

      next_metadata =
        page
        |> Map.drop(~w(items next_cursor truncated omitted_count snapshot_hash))
        |> Map.merge(metadata)

      case page["next_cursor"] do
        nil ->
          result =
            Map.merge(next_metadata, %{
              "items" => next_items,
              "next_cursor" => nil,
              "omitted_count" => 0,
              "truncated" => false,
              "snapshot_hash" => next_hash
            })

          if byte_size(Jason.encode!(result)) <= @max_bytes,
            do: {:ok, result},
            else: {:error, :result_limit_exceeded}

        next when is_binary(next) ->
          collect(
            query,
            operation,
            run_id,
            next,
            next_items,
            next_hash,
            next_metadata,
            pages + 1
          )

        _invalid ->
          {:error, :invalid_inspection_query}
      end
    else
      false -> {:error, :result_limit_exceeded}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_inspection_query}
    end
  rescue
    _exception -> {:error, :invalid_inspection_query}
  catch
    _kind, _reason -> {:error, :invalid_inspection_query}
  end
end
