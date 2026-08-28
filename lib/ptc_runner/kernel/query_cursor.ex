defmodule PtcRunner.Kernel.QueryCursor do
  @moduledoc false

  @type offset_result :: {:ok, non_neg_integer()} | {:error, :invalid_query | :source_changed}

  @doc false
  @spec query_digest(term()) :: binary()
  def query_digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  @doc false
  @spec page_options(map(), binary(), term(), pos_integer(), pos_integer(), pos_integer()) ::
          {:ok, %{limit: pos_integer(), offset: non_neg_integer(), query_id: binary()}}
          | {:error, :invalid_query | :source_changed}
  def page_options(
        arguments,
        source_id,
        query,
        default_limit,
        max_limit,
        max_cursor_bytes
      )
      when is_map(arguments) and is_binary(source_id) and is_integer(default_limit) and
             default_limit > 0 and is_integer(max_limit) and max_limit >= default_limit and
             is_integer(max_cursor_bytes) and max_cursor_bytes > 0 do
    limit = Map.get(arguments, "limit", default_limit)
    query_id = query_digest(query)

    with true <- is_integer(limit) and limit in 1..max_limit,
         {:ok, offset} <-
           offset(Map.get(arguments, "cursor"), source_id, query_id, max_cursor_bytes) do
      {:ok, %{limit: limit, offset: offset, query_id: query_id}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_query}
    end
  end

  def page_options(
        _arguments,
        _source_id,
        _query,
        _default_limit,
        _max_limit,
        _max_cursor_bytes
      ),
      do: {:error, :invalid_query}

  @doc false
  @spec offset(term(), binary(), binary(), pos_integer()) :: offset_result()
  def offset(nil, source_id, query_id, max_cursor_bytes)
      when is_binary(source_id) and is_binary(query_id) and is_integer(max_cursor_bytes) and
             max_cursor_bytes > 0,
      do: {:ok, 0}

  def offset(cursor, source_id, query_id, max_cursor_bytes)
      when is_binary(cursor) and is_binary(source_id) and is_binary(query_id) and
             is_integer(max_cursor_bytes) and max_cursor_bytes > 0 and
             byte_size(cursor) <= max_cursor_bytes do
    with {:ok, encoded} <- Base.url_decode64(cursor, padding: false),
         {:ok,
          %{"offset" => offset, "source" => cursor_source, "query" => cursor_query} = payload} <-
           Jason.decode(encoded),
         true <- map_size(payload) == 3,
         true <- is_integer(offset) and offset >= 0,
         true <- is_binary(cursor_source) and is_binary(cursor_query) do
      cond do
        cursor_source != source_id -> {:error, :source_changed}
        cursor_query != query_id -> {:error, :invalid_query}
        true -> {:ok, offset}
      end
    else
      _invalid -> {:error, :invalid_query}
    end
  end

  def offset(_cursor, _source_id, _query_id, _max_cursor_bytes),
    do: {:error, :invalid_query}

  @doc false
  @spec encode(non_neg_integer(), binary(), binary()) :: binary()
  def encode(offset, source_id, query_id)
      when is_integer(offset) and offset >= 0 and is_binary(source_id) and is_binary(query_id) do
    %{"offset" => offset, "source" => source_id, "query" => query_id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end
end
