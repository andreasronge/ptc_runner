# PageIndex - Hierarchical Document Retrieval

A PtcRunner implementation inspired by [VectifyAI/PageIndex](https://github.com/VectifyAI/PageIndex), demonstrating vectorless, reasoning-based RAG using hierarchical tree indexing.

## Concept

PageIndex replaces vector embeddings with a two-phase approach:

1. **Index Generation**: Parse documents into hierarchical tree structures (like a table of contents), with LLM-generated summaries at each node
2. **Reasoning-Based Retrieval**: LLM traverses the tree through logical inference, deciding which branches to explore based on summaries

```
Document                          Tree Index
┌────────────────────┐           ┌─────────────────────────────────┐
│ Chapter 1          │           │ {title: "Chapter 1"             │
│   Section 1.1      │    →      │  summary: "Overview of..."      │
│   Section 1.2      │           │  children: [                    │
│ Chapter 2          │           │    {title: "Section 1.1", ...}  │
│   ...              │           │    {title: "Section 1.2", ...}  │
└────────────────────┘           │  ]}                             │
                                 └─────────────────────────────────┘
```

Each tree node contains:
```elixir
%{
  node_id: "0006",
  title: "Financial Stability",
  summary: "The Federal Reserve's approach to...",  # LLM-generated
  start_index: 21,
  end_index: 28,
  children: [...]
}
```

## Setup

```bash
cd examples/page_index
mix deps.get
mix download                      # Download PDFs (~8 MB)
mix download --list               # List files without downloading
mix download --force              # Re-download existing files
```

This downloads:
- `3M_2022_10K.pdf` - Annual report for FY2022 questions
- `3M_2018_10K.pdf` - Annual report for baseline questions
- `3M_2023Q2_10Q.pdf` - Quarterly report for Q2 2023 questions

Test questions with ground truth answers are in `data/questions.json`.

## Why This Approach?

| Traditional RAG | PageIndex / Tree RAG |
|-----------------|---------------------|
| Chunk → embed → vector search | Parse → summarize → tree navigation |
| Semantic similarity (opaque) | Logical reasoning (interpretable) |
| Fixed chunk boundaries | Natural document structure |
| Returns "similar" chunks | Returns relevant sections with context |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Phase 1: Indexing (Elixir + SubAgents)                         │
│                                                                 │
│  Document → Parser → Sections → [SubAgent: Summarize] → Tree   │
│                                      ↓                         │
│                              (parallel via pmap                │
│                               or Task.async_stream)            │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ Phase 2: Retrieval (SubAgent with :self + llm_query)           │
│                                                                 │
│  Query → Navigator Agent → Tree Traversal → Relevant Sections  │
│              ↓                    ↓                             │
│         Reasons about        Uses :self for                    │
│         summaries            recursive exploration             │
└─────────────────────────────────────────────────────────────────┘
```

## Implementation

### Phase 1: Indexing

The indexer parses documents and generates summaries:

```elixir
defmodule PageIndex.Indexer do
  alias PtcRunner.SubAgent

  def index(document_path, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)

    # 1. Parse document into sections (preserving hierarchy)
    sections = Parser.parse(document_path)

    # 2. Generate summaries in parallel
    summaries = generate_summaries(sections, llm)

    # 3. Build tree structure
    TreeBuilder.build(sections, summaries)
  end

  defp generate_summaries(sections, llm) do
    sections
    |> Task.async_stream(fn section ->
      {:ok, step} = SubAgent.run(
        "Summarize this section in 1-2 sentences for a table of contents",
        context: %{title: section.title, content: section.content},
        output: :json,
        signature: "{summary :string}",
        llm: llm
      )
      {section.id, step.return["summary"]}
    end, max_concurrency: 10)
    |> Enum.into(%{}, fn {:ok, result} -> result end)
  end
end
```

### Phase 2: Retrieval

The navigator agent traverses the tree using reasoning:

```elixir
defmodule PageIndex.Retriever do
  alias PtcRunner.SubAgent

  def retrieve(tree, query, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)

    navigator = SubAgent.new(
      prompt: navigator_prompt(),
      signature: "(query :string, tree :map) -> [{node_id :string, relevance :float, excerpt :string}]",
      tools: %{
        "get-content" => &get_content/1,
        "explore-subtree" => :self  # Recursive for deep trees
      },
      llm_query: true,  # For relevance judgment
      max_turns: 15,
      max_depth: 4
    )

    SubAgent.run(navigator,
      context: %{query: query, tree: tree},
      llm: llm
    )
  end

  defp navigator_prompt do
    """
    Find sections relevant to: {{query}}

    ## Input
    - data/tree: Hierarchical document index
    - Each node has: :title, :summary, :node_id, :start_index, :end_index, :children

    ## Strategy
    1. Read the root node's children summaries
    2. Use tool/llm-query to judge which branches are relevant
    3. Explore promising branches (use tool/explore-subtree for deep trees)
    4. Fetch content with tool/get-content for final verification
    5. Return relevant sections with excerpts

    ## Tools
    - `tool/get-content {:start N :end M}` - Fetch page content
    - `tool/explore-subtree {:query Q :tree subtree}` - Recursive exploration
    - `tool/llm-query` - Judge relevance of summaries
    """
  end
end
```

### PTC-Lisp Navigation Logic

The agent uses `tree-seq` to flatten the document tree, then scores and filters nodes:

```clojure
;; Flatten tree, score nodes in parallel, return top matches
(->> (tree-seq :children :children data/tree)
     (remove :children)  ; only leaf nodes have content
     (pmap (fn [node]
             (let [result (tool/llm-query
                           {:prompt "Rate relevance of '{{summary}}' to '{{query}}'"
                            :signature "{score :float}"
                            :summary (:summary node)
                            :query data/query})]
               (assoc node :score (:score result)))))
     (filter #(> (:score %) 0.5))
     (sort-by :score >)
     (take 5)
     (map (fn [node]
            {:node_id (:node_id node)
             :relevance (:score node)
             :excerpt (tool/get-content {:start (:start_index node)
                                         :end (:end_index node)})})))
```

### Optimization: Beam Search for Deep Trees

The simple approach scores all nodes upfront. For deep trees with expensive scoring, prune early using recursive exploration:

```clojure
;; Only explore promising branches (beam search)
(defn explore [node]
  (if (empty? (:children node))
    [node]  ; leaf
    (let [scored (->> (:children node)
                      (pmap #(assoc % :score (score-node %)))
                      (filter #(> (:score %) 0.5))
                      (sort-by :score >)
                      (take 3))]
      (mapcat explore scored))))

(explore data/tree)
```

| Approach | LLM Calls | Best For |
|----------|-----------|----------|
| `tree-seq` + filter | All nodes | Shallow trees, fast scoring |
| Beam search | Only promising branches | Deep trees, expensive scoring |

## Usage

```bash
cd examples/page_index
mix deps.get
mix download

# Index a document
mix run run.exs --index data/3M_2022_10K.pdf

# Query the index (example from FinanceBench)
mix run run.exs --query "What drove operating margin change as of FY2022 for 3M?"

# With tracing
mix run run.exs --query "..." --trace
```

## Test Data

Questions in `data/questions.json` are from [FinanceBench](https://github.com/patronus-ai/financebench) (MIT license). Each question includes:

- Ground truth answer
- Expected document sections (for tree-RAG validation)
- Difficulty and tree-RAG advantage ratings

Test sets:
- `tree_rag_showcase` - Questions where tree navigation excels
- `baseline_comparison` - Simple lookups (vector search baseline)
- `full` - All 8 questions

## Key PtcRunner Features Used

| Feature | Usage |
|---------|-------|
| `Task.async_stream` | Parallel summary generation during indexing |
| `pmap` | Parallel branch exploration in PTC-Lisp |
| `:self` tool | Recursive subtree exploration |
| `llm_query: true` | Ad-hoc relevance judgments |
| `output: :json` | Structured summary extraction |
| Tracing | Visualize navigation path |

## Alternative Implementations

### Alternative 2: Pure RLM Style

Let the LLM discover the navigation algorithm without explicit guidance:

```elixir
SubAgent.new(
  prompt: """
  Find sections answering: {{query}}
  data/tree contains the document index. Navigate efficiently.
  """,
  tools: %{"search" => :self, "get-content" => &get_content/1},
  llm_query: true
)
```

More autonomous but less predictable. Good for exploring what strategies the LLM discovers.

### Alternative 3: Explicit Tree Tools

Provide fine-grained tree navigation tools:

```elixir
tools = %{
  "get-root" => fn _ -> tree.root end,
  "get-children" => fn %{node_id: id} -> get_children(tree, id) end,
  "get-summary" => fn %{node_id: id} -> get_node(tree, id).summary end,
  "get-content" => fn %{node_id: id} -> fetch_content(tree, id) end
}
```

More control, but requires more tool calls. Good when tree structure is complex or latency matters.

### Alternative 4: Plan-Then-Execute

Two-phase approach with explicit planning:

```elixir
# Phase 1: Generate navigation plan
{:ok, plan} = SubAgent.run(
  "Given this tree summary, plan which branches to explore",
  context: %{tree_summary: summarize_tree(tree), query: query},
  output: :json,
  signature: "{branches [:string], rationale :string}"
)

# Phase 2: Execute plan
{:ok, results} = SubAgent.run(
  "Execute exploration plan",
  context: %{plan: plan.return, tree: tree},
  tools: navigation_tools
)
```

Most interpretable. Good for debugging or when you need audit trails.

## Advanced: MetaPlanner for Multi-Document QA

For complex scenarios beyond single-document retrieval, the [MetaPlanner](../../docs/guides/subagent-meta-planner.md) provides autonomous planning with self-correction.

### When to Use MetaPlanner

| Scenario | Recommended Approach |
|----------|---------------------|
| Single document, single query | Navigator with `:self` (this example) |
| Multi-document comparison | MetaPlanner |
| Quality-assured indexing | MetaPlanner with verification |
| Queries requiring multi-hop reasoning | MetaPlanner |
| Real-time low-latency | Direct SubAgent calls |

### Example: Multi-Document Retrieval

Compare data across multiple annual reports:

```elixir
alias PtcRunner.PlanExecutor

mission = """
Compare 3M's operating margin between FY2021 and FY2022.
Explain what drove the change.
"""

result = PlanExecutor.run(mission,
  llm: llm,
  available_tools: %{
    "navigate_tree" => "Navigate document tree. Input: {doc_id, query}. Output: {sections}",
    "get_content" => "Fetch page content. Input: {doc_id, start, end}. Output: {text}"
  },
  base_tools: %{
    "navigate_tree" => &PageIndex.navigate/2,
    "get_content" => &PageIndex.get_content/3
  },
  max_total_replans: 3
)
```

MetaPlanner generates a plan like:

```json
{
  "tasks": [
    {
      "id": "find_2022_margin",
      "input": "Find operating margin in 2022 10K",
      "verification": "(number? (get data/result \"margin\"))",
      "on_verification_failure": "replan"
    },
    {
      "id": "find_2021_margin",
      "input": "Find operating margin in 2021 10K"
    },
    {
      "id": "find_drivers",
      "input": "Find cost and revenue factors affecting margin",
      "depends_on": ["find_2022_margin", "find_2021_margin"],
      "on_verification_failure": "replan"
    },
    {
      "id": "synthesize",
      "input": "Explain margin change from {{results.find_2021_margin}} to {{results.find_2022_margin}}",
      "type": "synthesis_gate",
      "depends_on": ["find_2022_margin", "find_2021_margin", "find_drivers"]
    }
  ]
}
```

### Example: Quality-Assured Indexing

Ensure summaries meet quality criteria during index generation:

```elixir
# Generate plan with verification for each section
sections_plan = %{
  "tasks" => sections |> Enum.map(fn section ->
    %{
      "id" => "summarize_#{section.id}",
      "input" => "Summarize: #{section.title}\n\n#{section.content}",
      "verification" => """
        (let [s (get data/result "summary")]
          (and (string? s)
               (> (count s) 50)
               (< (count s) 500)
               (not (includes? s "I cannot"))))
      """,
      "on_verification_failure" => "retry"
    }
  end)
}

{:ok, plan} = Plan.parse(sections_plan)
{:ok, results, _meta} = PlanExecutor.execute(plan, "Index document", llm: llm)
```

Failed summaries are automatically retried with feedback about why verification failed.

### Example: Adaptive Retrieval Strategy

Let MetaPlanner choose the retrieval approach based on query complexity:

```elixir
mission = """
Answer: "#{query}"

Available documents: #{Enum.join(doc_ids, ", ")}
Available strategies:
- tree_navigation: Follow document hierarchy (good for structured lookups)
- cross_reference: Compare across documents (good for trend analysis)
- exhaustive_scan: Check all sections (good for comprehensive answers)

Choose the most efficient strategy for this query.
"""

result = PlanExecutor.run(mission,
  llm: llm,
  available_tools: navigation_tool_descriptions,
  base_tools: navigation_tools,
  constraints: "Minimize LLM calls. Use parallel tasks when independent."
)
```

### Self-Correction in Action

When a task fails verification, MetaPlanner captures the failure and replans:

```
Task "find_drivers" failed verification:
  Output: {"factors": []}
  Diagnosis: "Expected non-empty factors list"

Replanning with context:
  - Completed: find_2022_margin (19.1%), find_2021_margin (20.1%)
  - Failed: find_drivers returned empty list

New plan: Search for "cost increase", "supply chain", "inflation" in MD&A section
```

This trial history prevents repeating failed approaches.

### Combining with Tree Navigation

MetaPlanner orchestrates high-level workflow; tree navigation handles document exploration:

```elixir
# MetaPlanner task calls into tree navigator
base_tools = %{
  "navigate_tree" => fn %{doc_id: doc_id, query: query} ->
    tree = load_index(doc_id)
    {:ok, step} = PageIndex.Retriever.retrieve(tree, query, llm: llm)
    step.return
  end
}
```

The navigator uses `:self` recursion internally while MetaPlanner handles cross-document coordination and verification.

## Tree Functions in PTC-Lisp

PTC-Lisp provides tree traversal builtins:

```clojure
;; tree-seq: flatten tree for filtering
(->> (tree-seq :children :children data/tree)
     (filter #(str/includes? (:summary %) "revenue"))
     (map :node_id))

;; postwalk: transform all nodes (bottom-up)
(postwalk #(if (map? %) (assoc % :visited true) %) tree)

;; prewalk: transform all nodes (top-down)
(prewalk #(if (:children %) (update % :children vec) %) tree)
```

## Comparison with Original PageIndex

| Aspect | Original (Python) | PtcRunner |
|--------|-------------------|-----------|
| Indexing | Sequential LLM calls | Parallel via Task.async_stream |
| Navigation | Prompt chaining | Single agent with `:self` recursion |
| Judgment | Inline in prompts | `llm_query` or `LLMTool` |
| Parallelism | Limited | Native `pmap` in PTC-Lisp |
| Observability | Manual logging | Built-in tracing |

## References

- [VectifyAI/PageIndex](https://github.com/VectifyAI/PageIndex) - Original implementation
- [Meta Planner Guide](../../docs/guides/subagent-meta-planner.md) - Autonomous planning with self-correction
- [RLM Patterns Guide](../../docs/guides/subagent-rlm-patterns.md) - Recursive Language Model patterns
- [Composition Patterns](../../docs/guides/subagent-patterns.md) - SubAgent orchestration
- [`examples/rlm_recursive/`](../rlm_recursive/) - Related: recursive benchmark agents
