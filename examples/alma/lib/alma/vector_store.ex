defmodule Alma.VectorStore do
  @moduledoc "In-process vector store with cosine similarity for both dense and sparse vectors."

  @doc "Returns an empty vector store."
  def new, do: %{entries: %{}, next_id: 1}

  @doc """
  Stores text with a pre-computed vector. Returns `{id, updated_store}`.

  The vector can be either a dense list of floats (from a real embedding model)
  or a sparse map of n-gram frequencies (from `embed/1`).
  """
  def store(store, text, vector, metadata \\ %{}, collection \\ "default") do
    id = store.next_id
    entry = %{vector: vector, text: text, metadata: metadata, collection: collection}

    updated =
      store
      |> put_in([:entries, id], entry)
      |> Map.put(:next_id, id + 1)

    {id, updated}
  end

  @doc """
  Finds the top-k most similar entries to `query_vector`.

  The `query_vector` must be the same type (dense list or sparse map) as the
  stored vectors. Pass `nil` for `collection` to search all entries.

  Returns a list of maps: `[%{"score" => float, "text" => string, "metadata" => map}]`,
  sorted by descending similarity score.
  """
  def find_similar(store, query_vector, k \\ 3, collection \\ nil) do
    store.entries
    |> Enum.filter(fn {_id, entry} ->
      is_nil(collection) or Map.get(entry, :collection) == collection
    end)
    |> Enum.map(fn {_id, entry} ->
      score = cosine_similarity(query_vector, entry.vector)
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
  Computes cosine similarity between two vectors.

  Supports both dense vectors (lists of floats) and sparse vectors (maps).
  Returns a float between 0.0 and 1.0. Returns 0.0 when either vector is empty.
  """
  # Dense vectors (lists of floats from real embeddings)
  def cosine_similarity([], _), do: 0.0
  def cosine_similarity(_, []), do: 0.0

  def cosine_similarity(vec_a, vec_b) when is_list(vec_a) and is_list(vec_b) do
    {dot, norm_sq_a, norm_sq_b} =
      Enum.zip(vec_a, vec_b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {a, b}, {d, na, nb} ->
        {d + a * b, na + a * a, nb + b * b}
      end)

    norm_a = :math.sqrt(norm_sq_a)
    norm_b = :math.sqrt(norm_sq_b)

    if norm_a == 0.0 or norm_b == 0.0, do: 0.0, else: dot / (norm_a * norm_b)
  end

  # Sparse vectors (maps of n-gram frequencies)
  def cosine_similarity(vec_a, vec_b) when vec_a == %{} or vec_b == %{}, do: 0.0

  def cosine_similarity(vec_a, vec_b) when is_map(vec_a) and is_map(vec_b) do
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
