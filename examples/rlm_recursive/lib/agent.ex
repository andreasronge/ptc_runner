defmodule RlmRecursive.Agent do
  @moduledoc """
  Recursive agent builder for RLM benchmarks.

  Creates SubAgents with `:self` tool for true recursive patterns where
  the LLM decides how to decompose the problem.

  ## Key Features

    * Uses `:self` tool for recursive self-invocation
    * Budget-aware via `(budget/remaining)` introspection
    * Grep-based probing using stdlib `grep` and `grep-n` functions

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

    * `type` - Agent type:
      * `:sniah` - Needle-in-haystack search with grep probing
      * `:counting` - Count profiles matching criteria
      * `:pairs` - Find pairs sharing city + hobby (keyword matching)
      * `:semantic_pairs` - Find semantically compatible pairs (pure RLM, minimal prompt)
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
      tools: %{"search" => :self},
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
      tools: %{"count" => :self},
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
      tools: %{"find_pairs" => :self},
      max_depth: max_depth,
      max_turns: max_turns,
      llm: llm
    )
  end

  def new(:semantic_pairs, opts) do
    # Pure RLM mode: minimal prompt, model discovers algorithm
    # Tests whether the model can independently discover:
    # 1. The need to batch process for efficiency
    # 2. A two-phase approach (semantic classification → programmatic pairing)
    # 3. Category-based compatibility matching
    max_depth = Keyword.get(opts, :max_depth, 4)
    max_turns = Keyword.get(opts, :max_turns, 100)
    turn_budget = Keyword.get(opts, :turn_budget, 200)
    llm = Keyword.get(opts, :llm)

    SubAgent.new(
      prompt: semantic_pairs_prompt(),
      signature: "(corpus :string) -> {count :int, pairs [:string]}",
      description: "Find pairs with semantically compatible interests",
      tools: %{"process" => :self},
      max_depth: max_depth,
      max_turns: max_turns,
      turn_budget: turn_budget,
      llm: llm,
      timeout: 600_000,
      pmap_timeout: 600_000
    )
  end

  # S-NIAH prompt with grep-based probing and budget-aware recursion
  defp sniah_prompt do
    """
    Find the answer to the query in the corpus.

    ## Strategy

    Use grep-based probing to efficiently search:
    1. Extract the search term from the query (e.g., "agent_7291" from "What is the access code for agent_7291?")
    2. Use `(grep-n search_term data/corpus)` to find matching lines with line numbers
    3. If matches found, extract the answer from the matching line(s)
    4. If corpus is very large and grep returns many matches, subdivide and recurse

    ## Budget Awareness

    Check `(budget/remaining)` before recursing:
    - If at depth limit, process directly
    - If low on turns, process directly
    - Otherwise, subdivide and use `tool/search` recursively

    ## Input
    - data/corpus: The text corpus to search
    - data/query: The question to answer (e.g., "What is the access code for agent_7291?")

    ## Output
    Return `{:answer "THE_CODE" :found true}` if found, or `{:answer nil :found false}` if not found.

    ## Example

    ```clojure
    ;; Extract search term from query
    (def search-term (get-in (re-find #"for (\\S+)" data/query) [1]))

    ;; Probe with grep-n to find matches with line numbers
    (def matches (grep-n search-term data/corpus))

    (cond
      ;; No matches found
      (empty? matches)
      (return {:answer nil :found false})

      ;; Found matches - extract answer
      :else
      (let [match-text (:text (first matches))
            ;; Extract code after "is " (e.g., "The access code for agent_7291 is XKQMTR")
            code (last (split match-text " "))]
        (return {:answer code :found true})))
    ```
    """
  end

  # Counting prompt - demonstrates RLM pattern: bulk data in memory, not LLM context
  defp counting_prompt do
    """
    Count profiles in the corpus that match the criteria.

    ## RLM Pattern: Data Lives in Memory

    The corpus can be large (10K+ profiles). Process it directly in code -
    the computer can filter millions of items instantly. This is the RLM insight:
    bulk data stays in memory, the LLM just writes processing code.

    ## Input
    - data/corpus: Profile lines (format: "PROFILE N: name=..., age=N, city=..., hobbies=[...]")
    - data/min_age: Minimum age threshold (count profiles with age > min_age)
    - data/hobby: Hobby to match (must appear in hobbies list)

    ## Output
    Return `{:count N}` where N is the count of matching profiles.

    ## Example

    ```clojure
    (def lines (split-lines data/corpus))
    (println "Processing" (count lines) "profiles...")

    (def matching
      (filter
        (fn [line]
          (let [age (extract-int "age=(\\\\d+)" line 1 0)]
            (and (> age data/min_age) (includes? line data/hobby))))
        lines))

    (return {:count (count matching)})
    ```

    ## Optional: Recursion for Very Large Data

    If you need to subdivide (e.g., for parallel processing or if context is limited),
    use `tool/count` to recurse:

    ```clojure
    (let [mid (quot n 2)
          r1 (tool/count {:corpus (join "\\n" (take mid lines)) :min_age data/min_age :hobby data/hobby})
          r2 (tool/count {:corpus (join "\\n" (drop mid lines)) :min_age data/min_age :hobby data/hobby})]
      (return {:count (+ (:count r1) (:count r2))}))
    ```
    """
  end

  # OOLONG-Pairs prompt - O(n^2) task where recursion is ESSENTIAL
  defp pairs_prompt do
    """
    Find all pairs of profiles where both people live in the same city AND share at least one hobby.

    ## WHY RECURSION IS ESSENTIAL

    This is an O(n^2) task - comparing all pairs directly will:
    - Explode memory for large n
    - Take too long in a single pass

    **Strategy: Divide by city, then aggregate**

    1. Group profiles by city (reduces n^2 to sum of smaller n^2)
    2. For each city group, find pairs within that group
    3. If a city group is still large (> 30 profiles), recurse

    ## Input
    - data/corpus: Profile lines (format: "PROFILE N: name=..., city=CITY, hobbies=[h1, h2, ...]")

    ## Output
    Return `{:count N :pairs ["1-2" "3-5" ...]}` where pairs are "id1-id2" strings (id1 < id2).

    ## REQUIRED Recursive Pattern

    ```clojure
    (def lines (split-lines data/corpus))
    (println "Processing" (count lines) "profiles...")

    ;; Parse profiles - use simple patterns to avoid complex escaping
    (defn parse-profile [line]
      {:id (extract-int "PROFILE (\\\\d+)" line 1 0)
       :city (extract "city=([^,]+)" line)
       :hobbies (let [raw (extract "hobbies=(.+)" line)]
                  (if raw (split (subs raw 1 (dec (count raw))) ", ") []))  ; trim [ ]
       :line line})

    (def profiles (map parse-profile lines))
    (def by-city (group-by :city profiles))
    (println "Cities:" (keys by-city))

    ;; Find pairs within each city group
    (defn shares-hobby [p1 p2]
      (some #(contains? (set (:hobbies p2)) %) (:hobbies p1)))

    (defn find-pairs-in-group [group]
      (if (> (count group) 30)
        ;; Too large - recurse with just this city's profiles
        (:pairs (tool/find_pairs {:corpus (join "\\n" (map :line group))}))
        ;; Small enough - use pairs function to generate all combinations
        (->> (pairs group)
             (filter (fn [[p1 p2]] (shares-hobby p1 p2)))
             (map (fn [[p1 p2]] (str (:id p1) "-" (:id p2)))))))

    (def all-pairs (flatten (map find-pairs-in-group (vals by-city))))
    (return {:count (count all-pairs) :pairs (take 20 all-pairs)})
    ```
    """
  end

  # Pure RLM prompt - minimal guidance, model discovers algorithm
  defp semantic_pairs_prompt do
    """
    Find all pairs of people in the same city with semantically compatible interests.

    ## Task

    Given a corpus of profiles, find pairs where:
    1. Both people live in the same city
    2. Their interests are semantically compatible (they would enjoy activities together)

    Semantic compatibility means understanding what activities MEAN, not keyword matching.
    "enjoys scaling peaks" and "trail running enthusiast" are compatible (both outdoor/active).
    "builds Arduino projects" and "pottery hobbyist" are NOT compatible (unrelated domains).

    ## Input
    - `data/corpus`: Profile lines (format: "PROFILE N: name=..., city=CITY, interests=[...]")

    ## Output
    Return `{:count N :pairs ["id1-id2" ...]}` where pairs have compatible interests.
    Format pairs as "id1-id2" with id1 < id2.

    ## Available Tool
    - `tool/process`: Recursively invoke this agent on a subset of the problem

    ## Notes
    - The corpus may be large (100+ profiles)
    - Semantic understanding requires LLM reasoning
    - Code can process structured data instantly
    - You have access to `(pairs coll)` for generating all 2-combinations
    - Check `(budget/remaining)` to monitor turn usage
    """
  end
end
