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

    * `type` - Either `:sniah` or `:counting`
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
          (let [age-match (re-find (re-pattern "age=(\\\\d+)") line)
                age (if age-match (parse-long (get age-match 1)) 0)]
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
end
