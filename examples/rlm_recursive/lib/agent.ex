defmodule RlmRecursive.Agent do
  @moduledoc """
  Recursive agent builder for RLM benchmarks.

  Pure RLM implementation: minimal prompts where the model discovers
  the optimal algorithm independently. Tests whether models can:

  - Identify when data is too large for single-turn processing
  - Decompose problems using recursive self-calls
  - Write efficient code (tool/grep probing, city grouping, batching, etc.)

  ## Example

      agent = RlmRecursive.Agent.new(:sniah)
      {:ok, step} = SubAgent.run(agent,
        context: %{"corpus" => corpus, "query" => query},
        llm: llm
      )

  """

  alias PtcRunner.SubAgent

  @doc """
  Create a new recursive agent for the specified benchmark type.

  ## Arguments

    * `type` - Agent type (all use pure RLM minimal prompts):
      * `:sniah` - Needle-in-haystack search
      * `:counting` - Count profiles matching criteria
      * `:pairs` - Find pairs sharing city + hobby
      * `:semantic_pairs` - Find semantically compatible pairs
    * `opts` - Options passed to SubAgent.new/1

  ## Options

    * `:max_depth` - Maximum recursion depth (default: 4)
    * `:max_turns` - Maximum turns per agent (default: 10)
    * `:llm` - LLM callback for the agent

  """
  def new(type, opts \\ [])

  def new(:sniah, opts) do
    max_depth = Keyword.get(opts, :max_depth, 4)
    max_turns = Keyword.get(opts, :max_turns, 10)
    llm = Keyword.get(opts, :llm)

    SubAgent.new(
      prompt: sniah_prompt(),
      signature: "(corpus :string, query :string) -> {answer :string, found :bool}",
      description: "Search corpus for answer to query",
      tools: %{"search" => :self},
      builtin_tools: [:grep],
      max_depth: max_depth,
      max_turns: max_turns,
      timeout: 60_000,
      pmap_timeout: 60_000,
      mission_timeout: 120_000,
      llm: llm
    )
  end

  def new(:counting, opts) do
    max_depth = Keyword.get(opts, :max_depth, 4)
    max_turns = Keyword.get(opts, :max_turns, 10)
    llm = Keyword.get(opts, :llm)

    SubAgent.new(
      prompt: counting_prompt(),
      signature: "(corpus :string, min_age :int, hobby :string) -> {count :int}",
      description: "Count profiles matching criteria",
      tools: %{"search" => :self},
      builtin_tools: [:grep],
      max_depth: max_depth,
      max_turns: max_turns,
      timeout: 60_000,
      pmap_timeout: 60_000,
      mission_timeout: 120_000,
      llm: llm
    )
  end

  def new(:pairs, opts) do
    max_depth = Keyword.get(opts, :max_depth, 5)
    max_turns = Keyword.get(opts, :max_turns, 15)
    llm = Keyword.get(opts, :llm)

    SubAgent.new(
      prompt: pairs_prompt(),
      signature: "(corpus :string) -> {count :int, pairs [:string]}",
      description: "Find pairs of profiles in same city with shared hobby",
      tools: %{"search" => :self},
      builtin_tools: [:grep],
      max_depth: max_depth,
      max_turns: max_turns,
      timeout: 60_000,
      pmap_timeout: 60_000,
      mission_timeout: 300_000,
      llm: llm
    )
  end

  def new(:semantic_pairs, opts) do
    # RLM + llm_query: recursive decomposition for data, ad-hoc LLM judgment for semantics
    # - tool/evaluate_pairs: recursive self-call for data decomposition
    # - tool/llm-query: builtin for batch semantic compatibility judgment
    max_depth = Keyword.get(opts, :max_depth, 4)
    max_turns = Keyword.get(opts, :max_turns, 100)
    turn_budget = Keyword.get(opts, :turn_budget, 200)
    llm = Keyword.get(opts, :llm)

    SubAgent.new(
      prompt: semantic_pairs_prompt(),
      signature: "(corpus :string) -> {count :int, pairs [:string]}",
      description: "Find pairs with semantically compatible interests",
      tools: %{"evaluate_pairs" => :self},
      builtin_tools: [:grep],
      llm_query: true,
      max_depth: max_depth,
      max_turns: max_turns,
      turn_budget: turn_budget,
      llm: llm,
      timeout: 60_000,
      pmap_timeout: 120_000,
      mission_timeout: 600_000,
      memory_strategy: :rollback
    )
  end

  defp sniah_prompt do
    """
    Find the answer to the query in the corpus.

    ## Input
    - data/corpus: The text to search (may be very large)
    - data/query: The question to answer

    ## Output
    Return `{:answer "THE_ANSWER" :found true}` if found, or `{:answer nil :found false}` if not found.

    ## Tools
    - `tool/grep` / `tool/grep-n`: Search the corpus directly — prefer this for simple lookups
    - `tool/search`: Recursive self-call for subdividing very large corpora
    """
  end

  defp counting_prompt do
    """
    Count profiles in the corpus that match the criteria.

    ## Input
    - data/corpus: Profile lines (format: "PROFILE N: name=..., age=N, city=..., hobbies=[...]")
    - data/min_age: Minimum age threshold (count profiles with age > min_age)
    - data/hobby: Hobby to match (must appear in hobbies list)

    ## Output
    Return `{:count N}` where N is the count of matching profiles.

    ## Tools
    - `tool/grep` / `tool/grep-n`: Filter the corpus directly — prefer this for O(n) filtering
    - `tool/search`: Recursive self-call for subdividing very large corpora
    """
  end

  defp pairs_prompt do
    """
    Find all pairs of profiles where both people live in the same city AND share at least one hobby.

    ## Input
    - data/corpus: Profile lines (format: "PROFILE N: name=..., city=CITY, hobbies=[h1, h2, ...]")

    ## Output
    Return `{:count N :pairs ["id1-id2" ...]}` where pairs are "id1-id2" strings (id1 < id2).

    ## Strategy
    This is an O(n²) problem. Use divide-and-conquer:
    1. Group profiles by city (only same-city profiles can be pairs)
    2. For each city group: if ≤ 5 profiles, compute pairs directly; if more, split and recurse with `tool/search`
    3. Merge all pairs from all city groups

    ## Tool
    - `tool/search`: Recursive self-call — pass a SUBSET of the corpus, never the full corpus unchanged
    """
  end

  defp semantic_pairs_prompt do
    """
    Find all pairs of people in the same city with semantically compatible interests.

    Semantic compatibility means understanding what activities MEAN, not keyword matching.
    Example: "enjoys scaling peaks" and "trail running enthusiast" are compatible (both outdoor/active).
    Example: "builds Arduino projects" and "pottery hobbyist" are NOT compatible (unrelated domains).

    ## Input
    - data/corpus: Profile lines (format: "PROFILE N: name=..., city=CITY, interests=[...]")

    ## Output
    Return `{:count N :pairs ["id1-id2" ...]}` where pairs are "id1-id2" strings (id1 < id2).

    ## Strategy
    The corpus may be very large. Do NOT generate all pairs in memory — this will exceed memory limits.
    Instead, use a chunking strategy:
    1. Split the corpus by city (each city is independent).
    2. For each city, if the group has more than 50 profiles, split it further and use
       `tool/evaluate_pairs` to process each sub-chunk recursively.
    3. For manageable chunks (≤50 profiles), generate pairs and use `tool/llm-query` to judge them.
    4. Merge results from all chunks.

    ## Tools
    - `tool/evaluate_pairs`: Recursive self-call. Pass a subset of the corpus as `{:corpus chunk}`.
      Use this to divide large city groups into smaller pieces.
    - `tool/llm-query`: Use for ALL semantic judgment — do NOT judge compatibility in code.
      Use signature `"[{id :string, compatible :bool}]"` for batch judgment.
      Pass pairs in batches of ≤50 to get accurate results.
    """
  end
end
