defmodule Alma.VectorStore do
  @moduledoc "In-process vector store with character n-gram cosine similarity."

  @doc "Returns an empty vector store."
  def new, do: %{entries: %{}, next_id: 1}

  @doc """
  Stores text with auto-generated embedding. Returns `{id, updated_store}`.
  """
  def store(store, text, metadata \\ %{}) do
    store(store, text, metadata, "default")
  end

  @doc """
  Stores text with auto-generated embedding in the given collection.

  Returns `{id, updated_store}`.
  """
  def store(store, text, metadata, collection) do
    id = store.next_id
    vector = embed(text)
    entry = %{vector: vector, text: text, metadata: metadata, collection: collection}

    updated =
      store
      |> put_in([:entries, id], entry)
      |> Map.put(:next_id, id + 1)

    {id, updated}
  end

  @doc """
  Finds the top-k most similar entries to `query_text`.

  Returns a list of maps: `[%{"score" => float, "text" => string, "metadata" => map}]`,
  sorted by descending similarity score.
  """
  def find_similar(store, query_text, k \\ 3) do
    find_similar(store, query_text, k, nil)
  end

  @doc """
  Finds the top-k most similar entries to `query_text`, optionally filtered by collection.

  When `collection` is `nil`, searches all entries (backward compatible).
  When `collection` is a string, only entries in that collection are searched.
  """
  def find_similar(store, query_text, k, collection) do
    query_vec = embed(query_text)

    store.entries
    |> Enum.filter(fn {_id, entry} ->
      is_nil(collection) or Map.get(entry, :collection) == collection
    end)
    |> Enum.map(fn {_id, entry} ->
      score = cosine_similarity(query_vec, entry.vector)
      %{"score" => score, "text" => entry.text, "metadata" => entry.metadata}
    end)
    |> Enum.sort_by(& &1["score"], :desc)
    |> Enum.take(k)
  end

  @doc """
  Embeds text as a character n-gram frequency vector (sparse map).

  Uses both 2-grams and 3-grams so that short strings (< 3 chars) still
  produce a non-empty vector. Returns `%{ngram => count}`.
  """
  def embed(text) do
    chars =
      text
      |> String.downcase()
      |> String.to_charlist()

    bigrams = chars |> Enum.chunk_every(2, 1, :discard) |> Enum.map(&List.to_string/1)
    trigrams = chars |> Enum.chunk_every(3, 1, :discard) |> Enum.map(&List.to_string/1)

    Enum.frequencies(bigrams ++ trigrams)
  end

  @doc """
  Computes cosine similarity between two sparse vectors (maps).

  Returns a float between 0.0 and 1.0. Returns 0.0 when either vector is empty.
  """
  def cosine_similarity(vec_a, vec_b) when vec_a == %{} or vec_b == %{}, do: 0.0

  def cosine_similarity(vec_a, vec_b) do
    dot =
      Enum.reduce(vec_a, 0.0, fn {key, val_a}, acc ->
        case Map.fetch(vec_b, key) do
          {:ok, val_b} -> acc + val_a * val_b
          :error -> acc
        end
      end)

    norm_a = norm(vec_a)
    norm_b = norm(vec_b)

    if norm_a == 0.0 or norm_b == 0.0 do
      0.0
    else
      dot / (norm_a * norm_b)
    end
  end

  defp norm(vec) do
    vec
    |> Map.values()
    |> Enum.reduce(0.0, fn v, acc -> acc + v * v end)
    |> :math.sqrt()
  end
end
