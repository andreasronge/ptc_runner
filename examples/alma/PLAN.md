# Plan: Real Embeddings for ALMA VectorStore

## Problem

ALMA's VectorStore uses character n-gram (bigram + trigram) frequency vectors for similarity search. This produces near-random cosine similarity scores (0.17–0.22) that cannot distinguish semantically related items. The consequence is severe:

- **Hallucinated locations**: querying "find key" returns "torch in room_F" at score 0.18. The recall code treats this as truth, navigates to room_F, and wastes the episode.
- **No semantic discrimination**: "key" vs "torch" vs "potion" all produce similar n-gram overlap, so `find-similar` returns essentially random results.
- **Compounding with stale data**: the vector store accumulates across episodes, but object placements randomize each episode. Stale entries crowd out relevant matches, and even "relevant" matches are unreliable due to embedding quality.

In the Feb 20 benchmark run (5 generations, Haiku), **every evolved design scored worse than the no-memory baseline** (0.59). The primary root cause is the n-gram embedder — the evolutionary loop cannot produce useful memory designs when the retrieval substrate returns garbage.

ReqLLM v1.2 (already a dependency) provides `ReqLLM.Embedding.embed/3` with support for OpenAI and Google embedding models. The fix is to wire this through LLMClient and into the MemoryHarness tool closures so `find-similar` returns semantically meaningful results.

## Architecture: Inversion of Control

### Why not inject the embedder into VectorStore?

The naive approach — making VectorStore call the embedding API internally — has a severe concurrency flaw. MemoryHarness wraps VectorStore in an Elixir Agent:

```elixir
# Current MemoryHarness tool closure
Agent.get(vs_agent, fn vs -> VectorStore.find_similar(vs, query, k, collection) end)
```

If `find_similar` calls the HTTP embedding API inside the Agent callback:

1. **Serialized concurrency**: In `evaluate_deployment`, all concurrent task streams share a single `vs_agent`. Multiple simultaneous recall calls queue at the Agent, executing one HTTP embedding call at a time. This serializes the entire deployment phase.
2. **GenServer timeouts**: Agent calls default to 5000ms timeout. Queueing several 200–500ms HTTP requests causes cascading timeouts and crashes.
3. **Loss of purity**: Pushing HTTP side-effects into a data structure makes isolated testing harder.

### The fix: embed outside the Agent lock

Keep VectorStore 100% pure. Change its API to accept pre-computed vectors. Move embedding I/O into the MemoryHarness tool closures, **outside** the Agent callback:

```elixir
# MemoryHarness tool closure (after)
"find-similar" => {fn args ->
    query = Map.fetch!(args, "query")
    query_vector = embed_fn.(query)  # HTTP I/O happens here, concurrently
    Agent.get(vs_agent, fn vs ->     # Agent lock: instant, pure lookup
      VectorStore.find_similar(vs, query_vector, k, collection)
    end)
end, ...}
```

This way:
- Multiple concurrent tasks can embed in parallel (no serialization)
- The Agent callback is instant (no timeout risk)
- VectorStore remains a pure data structure (easy to test with raw float lists)
- Batching and caching can be added later at the MemoryHarness level

## Design Decisions

1. **In-memory store stays** — at ALMA's scale (dozens to hundreds of vectors per run), a full vector DB is unnecessary.

2. **VectorStore stays pure** — no embedder injection. API changes from text-in to vector-in. The caller is responsible for computing embeddings before interacting with the store.

3. **LLMClient gets `embed/2`** — follows the same `parse_provider` → dispatch pattern as `generate_text`. Keeps the embedding API consistent with the rest of the LLM client.

4. **Dense cosine similarity** — the current `cosine_similarity/2` operates on sparse maps (`%{ngram => count}`). Real embeddings return dense lists (`[float]`). Add a list-based clause alongside the existing map-based one.

5. **`embed/1` stays as a public convenience** — the existing n-gram `embed/1` remains available for callers that want the old behavior (tests, offline use). It is no longer called internally by `store` or `find_similar`.

## Implementation Steps

### Step 1: Add `LLMClient.embed/2,3`

**Files**: `llm_client/lib/llm_client.ex`, `llm_client/lib/llm_client/providers.ex`

Add to `LLMClient.Providers`:

```elixir
def embed(model, input, opts \\ []) do
  case parse_provider(model) do
    {:ollama, model_name} ->
      call_ollama_embed(model_name, input, opts)

    {:openai_compat, base_url, model_name} ->
      call_openai_compat_embed(base_url, model_name, input, opts)

    {:req_llm, model_id} ->
      ReqLLM.Embedding.embed(model_id, input, opts)
  end
end
```

Add Ollama embedding support (`POST /api/embed`):

```elixir
defp call_ollama_embed(model, input, opts) do
  base_url = Keyword.get(opts, :ollama_base_url, @ollama_base_url)
  timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

  case Req.post("#{base_url}/api/embed",
         json: %{model: model, input: input},
         receive_timeout: timeout) do
    {:ok, %{status: 200, body: %{"embeddings" => [embedding]}}} when is_binary(input) ->
      {:ok, embedding}
    {:ok, %{status: 200, body: %{"embeddings" => embeddings}}} ->
      {:ok, embeddings}
    {:ok, %{status: status, body: body}} ->
      {:error, %{status: status, body: body}}
    {:error, reason} ->
      {:error, reason}
  end
end
```

Add delegation in `LLMClient`:

```elixir
def embed(model, input, opts \\ []) do
  with {:ok, resolved} <- LLMClient.Registry.resolve(model) do
    LLMClient.Providers.embed(resolved, input, opts)
  end
end

def embed!(model, input, opts \\ []) do
  case embed(model, input, opts) do
    {:ok, result} -> result
    {:error, reason} -> raise "Embedding error: #{inspect(reason)}"
  end
end
```

### Step 2: Change VectorStore API to accept pre-computed vectors

**File**: `examples/alma/lib/alma/vector_store.ex`

Change `store` to accept a pre-computed vector instead of computing it internally:

```elixir
# Before: store(store, text, metadata, collection) — calls embed(text) internally
# After:  store(store, text, vector, metadata, collection) — vector provided by caller

def store(store, text, vector, metadata \\ %{}, collection \\ "default") do
  id = store.next_id
  entry = %{vector: vector, text: text, metadata: metadata, collection: collection}

  updated =
    store
    |> put_in([:entries, id], entry)
    |> Map.put(:next_id, id + 1)

  {id, updated}
end
```

Change `find_similar` to accept a pre-computed query vector:

```elixir
# Before: find_similar(store, query_text, k, collection) — calls embed(query_text)
# After:  find_similar(store, query_vector, k, collection) — vector provided by caller

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
```

Keep `embed/1` as a public function for backward compatibility (tests, offline use). It is no longer called internally.

### Step 3: Add dense-vector cosine similarity

**File**: `examples/alma/lib/alma/vector_store.ex`

Add list-based clauses to `cosine_similarity/2` (above the existing map-based clauses):

```elixir
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

# Sparse vectors (maps — existing implementation, unchanged)
def cosine_similarity(vec_a, vec_b) when vec_a == %{} or vec_b == %{}, do: 0.0
def cosine_similarity(vec_a, vec_b) when is_map(vec_a) and is_map(vec_b) do
  # ... existing implementation unchanged ...
end
```

### Step 4: Wire embedding into MemoryHarness tool closures

**File**: `examples/alma/lib/alma/memory_harness.ex`

Build an `embed_fn` from opts and use it in the tool closures, **outside** the Agent lock:

```elixir
defp build_tools(vs_agent, gs_agent, opts) do
  embed_fn = build_embed_fn(opts)
  # ... pass embed_fn to tool closures
end

defp build_embed_fn(opts) do
  case Keyword.get(opts, :embed_model) do
    nil ->
      # Fallback: n-gram embedding (no API key needed)
      &VectorStore.embed/1

    model ->
      fn text -> LLMClient.embed!(model, text) end
  end
end
```

Update the `store-obs` tool closure:

```elixir
"store-obs" =>
  {fn args ->
     text = Map.fetch!(args, "text")
     metadata = Map.get(args, "metadata", %{})
     collection = Map.get(args, "collection", "default")

     vector = embed_fn.(text)  # I/O outside Agent lock

     Agent.get_and_update(vs_agent, fn vs ->
       {id, updated} = VectorStore.store(vs, text, vector, metadata, collection)
       {"stored:#{id}", updated}
     end)
   end, "(text :string, metadata :map, collection :string) -> :string"}
```

Update the `find-similar` tool closure:

```elixir
"find-similar" =>
  {fn args ->
     query = Map.fetch!(args, "query")
     k = Map.get(args, "k", 3)
     collection = Map.get(args, "collection")

     query_vector = embed_fn.(query)  # I/O outside Agent lock

     Agent.get(vs_agent, fn vs ->
       VectorStore.find_similar(vs, query_vector, k, collection)
     end)
   end, "(query :string, k :int, collection :string) -> [:map]"}
```

### Step 5: Update tests

**File**: `examples/alma/test/vector_store_test.exs`

Update existing tests to pass pre-computed vectors. Tests become simpler and more direct — no mock embedder closures needed:

```elixir
describe "store and find_similar with dense vectors" do
  test "finds most similar vector" do
    store = VectorStore.new()
    {_, store} = VectorStore.store(store, "cat", [1.0, 0.0, 0.0])
    {_, store} = VectorStore.store(store, "dog", [0.9, 0.1, 0.0])
    {_, store} = VectorStore.store(store, "quantum", [0.0, 0.0, 1.0])

    [top | _] = VectorStore.find_similar(store, [0.95, 0.05, 0.0], 2)
    assert top["text"] == "cat"
  end

  test "orthogonal vectors score 0.0" do
    store = VectorStore.new()
    {_, store} = VectorStore.store(store, "x-axis", [1.0, 0.0, 0.0])

    [result] = VectorStore.find_similar(store, [0.0, 1.0, 0.0], 1)
    assert_in_delta result["score"], 0.0, 1.0e-10
  end
end

describe "cosine_similarity/2 with dense vectors" do
  test "identical vectors have similarity 1.0" do
    vec = [0.5, 0.3, 0.8]
    assert_in_delta VectorStore.cosine_similarity(vec, vec), 1.0, 1.0e-10
  end

  test "empty list returns 0.0" do
    assert VectorStore.cosine_similarity([], [1.0, 2.0]) == 0.0
    assert VectorStore.cosine_similarity([1.0, 2.0], []) == 0.0
  end
end
```

Existing n-gram tests: update `store` calls to pass `VectorStore.embed(text)` as the vector argument explicitly (or keep a small helper). The `embed/1` function remains public.

**File**: `llm_client/test/` — Add test for `LLMClient.embed/2` (mock or fixture-based, no real API calls in CI).

### Step 6: Configuration and documentation

- Add `EMBED_MODEL` to `.env.example` with default `openai:text-embedding-3-small`
- Update `examples/alma/README.md` to document the `--embed-model` option
- Update FUTURE.md to mark "Real embeddings" as implemented

## Cost Estimate

Per ALMA iteration (~60–120 embeddings of ~50 tokens each):
- `openai:text-embedding-3-small`: ~$0.0001 per iteration
- `openai:text-embedding-3-large`: ~$0.0004 per iteration
- Negligible compared to LLM generation costs in the same run

## Open Questions

1. **Embedding model alias**: should `LLMClient.Registry` support aliases for embedding models (e.g. `"embed-small"` → `"openai:text-embedding-3-small"`)? Not needed for v1 but convenient.
2. **Batch embedding**: the inversion-of-control design naturally supports batching later — MemoryHarness can batch-embed multiple texts before updating the Agent in a single call.
3. **Caching**: by keeping embedding at the MemoryHarness level, caching is localized. A simple ETS cache keyed by `{model, text}` can be added without touching VectorStore. Defer until profiling shows it matters.
