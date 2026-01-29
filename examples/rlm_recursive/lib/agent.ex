defmodule RlmRecursive.Agent do
  @moduledoc """
  Recursive agent builder for RLM benchmarks.

  Pure RLM implementation: minimal prompts where the model discovers
  the optimal algorithm independently. Tests whether models can:

  - Identify when data is too large for single-turn processing
  - Decompose problems using recursive self-calls
  - Write efficient code (grep probing, city grouping, batching, etc.)

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
      description: "Search corpus for answer to query using recursive subdivision",
      tools: %{"query" => :self},
      max_depth: max_depth,
      max_turns: max_turns,
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
      description: "Count profiles matching criteria using recursive aggregation",
      tools: %{"query" => :self},
      max_depth: max_depth,
      max_turns: max_turns,
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
      description:
        "Find pairs of profiles in same city with shared hobby - uses recursion for O(n^2) task",
      tools: %{"query" => :self},
      max_depth: max_depth,
      max_turns: max_turns,
      llm: llm
    )
  end

  def new(:semantic_pairs, opts) do
    # RLM + LLMTool: recursive decomposition for data, LLM judgment for semantics
    # - tool/evaluate_pairs: recursive self-call for data decomposition
    # - tool/judge_pairs: LLMTool for batch semantic compatibility judgment
    max_depth = Keyword.get(opts, :max_depth, 4)
    max_turns = Keyword.get(opts, :max_turns, 100)
    turn_budget = Keyword.get(opts, :turn_budget, 200)
    llm = Keyword.get(opts, :llm)

    judge_tool =
      PtcRunner.SubAgent.LLMTool.new(
        prompt: """
        Judge semantic compatibility for each pair of interests.
        Compatible = related domains (outdoor/fitness, creative/artistic, tech/science).
        NOT compatible = unrelated domains.

        Pairs to judge:
        {{#pairs}}
        - {{id1}} & {{id2}}: "{{interests1}}" vs "{{interests2}}"
        {{/pairs}}

        For each pair in the input, return whether the interests are compatible.
        """,
        signature:
          "(pairs [{id1 :int, id2 :int, interests1 :string, interests2 :string}]) -> [{id1 :int, id2 :int, compatible :bool}]",
        description:
          "Judge semantic compatibility of interest pairs in batch — returns list with compatible boolean per pair"
      )

    SubAgent.new(
      prompt: semantic_pairs_prompt(),
      signature: "(corpus :string) -> {count :int, pairs [:string]}",
      description: "Find pairs with semantically compatible interests",
      tools: %{"evaluate_pairs" => :self, "judge_pairs" => judge_tool},
      max_depth: max_depth,
      max_turns: max_turns,
      turn_budget: turn_budget,
      llm: llm,
      timeout: 600_000,
      pmap_timeout: 600_000
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

    ## Tool
    - `tool/query`: Recursive self-call
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

    ## Tool
    - `tool/query`: Recursive self-call
    """
  end

  defp pairs_prompt do
    """
    Find all pairs of profiles where both people live in the same city AND share at least one hobby.

    ## Input
    - data/corpus: Profile lines (format: "PROFILE N: name=..., city=CITY, hobbies=[h1, h2, ...]")

    ## Output
    Return `{:count N :pairs ["id1-id2" ...]}` where pairs are "id1-id2" strings (id1 < id2).

    ## Tool
    - `tool/query`: Recursive self-call
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

    ## Tools
    - `tool/evaluate_pairs`: Recursive self-call for data decomposition (splitting large datasets)
    - `tool/judge_pairs`: Judge semantic compatibility of interest pairs in batch.
      Call with `{:pairs [{:id1 N :id2 M :interests1 "..." :interests2 "..."} ...]}`.
      Returns `[{:id1 N :id2 M :compatible true/false} ...]`.
      Group pairs by city first, then call judge_pairs once per city with all same-city pairs.
      Use this for ALL semantic judgment — do NOT try to judge compatibility in code.
    """
  end
end
