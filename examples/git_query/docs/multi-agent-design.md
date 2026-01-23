# Multi-Agent Git Query Design

A planned architecture using specialized single-shot agents with clear separation of concerns.

## Design Goals

Address failure modes observed in single-agent execution:
- **Exploration addiction**: LLM wastes turns "understanding" visible data
- **Goal drift**: Constraints like "last week" get lost across turns
- **State uncertainty**: LLM stalls with println because it's unsure what to do

## Architecture Overview

```
┌───────────────────────────────────────────────────────────────────┐
│                        Always Present                              │
│  original_question: "interesting commits from last week"          │
│  tool_summary: [get_commits, get_author_stats, get_file_stats]    │
└───────────────────────────────────────────────────────────────────┘

┌─────────────┐       ┌─────────────┐       ┌─────────────┐
│  Architect  │       │   Fetcher   │       │  Evaluator  │
│             │       │             │       │             │
│ Sees tools  │       │ HAS tools   │       │ NO tools    │
│ Emits query │       │ max_turns:1 │       │ max_turns:1 │
│ or intent   │       │ Data only   │       │ Filter+Decide
└──────┬──────┘       └──────┬──────┘       └──────┬──────┘
       │                     │                     │
       ▼                     ▼                     ▼
   {:query ...}          data/*              {:done result}
   {:intent "..."}                           {:fetch hints}
   {:plan [...]}                             {:revise plan}
       │
       ▼
┌─────────────┐
│  Compiler   │
│             │
│ DSL → Lisp  │
│ (code or LLM)
└─────────────┘
```

### Key Design Principles

1. **North Star**: `original_question` is in every agent's context - prevents "telephone game" decay
2. **Tool-Aware Planning**: Architect sees tool summary so plans are grounded in reality
3. **Strict Turn Limits**: `max_turns: 1` for Fetcher/Evaluator enforces single-shot architecturally
4. **Hybrid Compilation**: Structured queries compile deterministically; complex intents use LLM

---

## Query DSL Specification

The Architect emits structured queries that compile deterministically to PTC-Lisp. This avoids LLM syntax errors and makes the intent explicit.

### Basic Structure

```clojure
{:query
  {:fetch [...]       ; Tool calls to make
   :transform [...]   ; Operations on fetched data
   :return {...}}}    ; Final output shape
```

### Fetch Clause

Declare which tools to call and bind results to names:

```clojure
{:fetch
  [{:tool :get_commits
    :as :commits
    :params {:since "1 week ago" :limit 50}}

   {:tool :get_author_stats
    :as :authors
    :params {:since "1 week ago"}}]}
```

**Compiles to**:
```clojure
(def commits (tool/get_commits {:since "1 week ago" :limit 50}))
(def authors (tool/get_author_stats {:since "1 week ago"}))
```

### Transform Clause

Chain operations on fetched data:

#### Filter
```clojure
{:op :filter
 :on :commits
 :as :large_commits
 :where [:> :files 5]}
```

**Compiles to**:
```clojure
(def large_commits (filter (fn [x] (> (:files x) 5)) commits))
```

#### Where Predicates

| Predicate | Example | Compiles to |
|-----------|---------|-------------|
| Comparison | `[:> :files 5]` | `(> (:files x) 5)` |
| Equality | `[:= :author "alice"]` | `(= (:author x) "alice")` |
| Contains | `[:contains :message "fix"]` | `(str-contains? (:message x) "fix")` |
| Matches | `[:matches :message "^fix\\|^feat"]` | `(re-find #"^fix\|^feat" (:message x))` |
| And | `[:and [:> :files 5] [:= :author "alice"]]` | `(and ...)` |
| Or | `[:or [:> :files 10] [:contains :message "major"]]` | `(or ...)` |
| Not | `[:not [:= :author "bot"]]` | `(not ...)` |

#### Sort
```clojure
{:op :sort
 :on :large_commits
 :as :ranked
 :by :files
 :order :desc}
```

**Compiles to**:
```clojure
(def ranked (sort-by :files > large_commits))
```

#### Take / Drop
```clojure
{:op :take :on :ranked :as :top5 :n 5}
{:op :drop :on :ranked :as :rest :n 5}
```

**Compiles to**:
```clojure
(def top5 (take 5 ranked))
(def rest (drop 5 ranked))
```

#### Map (Transform each item)
```clojure
{:op :map
 :on :commits
 :as :summaries
 :select [:hash :author :message]}
```

**Compiles to**:
```clojure
(def summaries (map (fn [x] {:hash (:hash x)
                              :author (:author x)
                              :message (:message x)}) commits))
```

#### Map with Computed Fields
```clojure
{:op :map
 :on :commits
 :as :with_score
 :select [:hash :author]
 :compute {:risk [:+ [:* :deletions 2] :additions]}}
```

**Compiles to**:
```clojure
(def with_score
  (map (fn [x] {:hash (:hash x)
                :author (:author x)
                :risk (+ (* (:deletions x) 2) (:additions x))})
       commits))
```

#### Group By
```clojure
{:op :group
 :on :commits
 :as :by_author
 :by :author}
```

**Compiles to**:
```clojure
(def by_author (group-by :author commits))
```

#### Aggregate
```clojure
{:op :aggregate
 :on :by_author
 :as :author_stats
 :compute {:count [:count]
           :total_files [:sum :files]
           :avg_files [:avg :files]}}
```

**Compiles to**:
```clojure
(def author_stats
  (map (fn [[author items]]
         {:author author
          :count (count items)
          :total_files (reduce + (map :files items))
          :avg_files (/ (reduce + (map :files items)) (count items))})
       by_author))
```

#### Join
```clojure
{:op :join
 :left :commits
 :right :author_details
 :on [:= :author :name]
 :as :enriched}
```

**Compiles to**:
```clojure
(def enriched
  (map (fn [c]
         (let [detail (first (filter (fn [a] (= (:author c) (:name a))) author_details))]
           (merge c detail)))
       commits))
```

#### First / Last
```clojure
{:op :first :on :ranked :as :top_commit}
{:op :last :on :ranked :as :bottom_commit}
```

**Compiles to**:
```clojure
(def top_commit (first ranked))
(def bottom_commit (last ranked))
```

### Return Clause

Specify the output shape:

```clojure
{:return
  {:findings :top5
   :summary "Found {{count:large_commits}} large commits, showing top 5"
   :metadata {:total "{{count:commits}}"
              :filtered "{{count:large_commits}}"}}}
```

**Template variables**:
- `{{name}}` - Insert value of binding
- `{{count:name}}` - Insert count of collection
- `{{first:name:field}}` - Insert field from first item

**Compiles to**:
```clojure
(return {:findings top5
         :summary (str "Found " (count large_commits) " large commits, showing top 5")
         :metadata {:total (count commits)
                    :filtered (count large_commits)}})
```

---

## Complete DSL Examples

### Example 1: Simple Query

**Question**: "Show commits from last week"

**Architect emits**:
```clojure
{:query
  {:fetch [{:tool :get_commits :as :commits :params {:since "1 week ago"}}]
   :return {:findings :commits
            :summary "Found {{count:commits}} commits from last week"}}}
```

**Compiled PTC-Lisp**:
```clojure
(def commits (tool/get_commits {:since "1 week ago"}))
(return {:findings commits
         :summary (str "Found " (count commits) " commits from last week")})
```

### Example 2: Filter and Sort

**Question**: "Large commits from last week, sorted by size"

**Architect emits**:
```clojure
{:query
  {:fetch [{:tool :get_commits :as :commits :params {:since "1 week ago"}}]
   :transform [{:op :filter :on :commits :as :large :where [:> :files 5]}
               {:op :sort :on :large :as :ranked :by :files :order :desc}]
   :return {:findings :ranked
            :summary "{{count:large}} large commits (5+ files)"}}}
```

### Example 3: Aggregation

**Question**: "Commits per author this month"

**Architect emits**:
```clojure
{:query
  {:fetch [{:tool :get_commits :as :commits :params {:since "1 month ago"}}]
   :transform [{:op :group :on :commits :as :by_author :by :author}
               {:op :aggregate :on :by_author :as :stats
                :compute {:count [:count] :files [:sum :files]}}
               {:op :sort :on :stats :as :ranked :by :count :order :desc}]
   :return {:findings :ranked
            :summary "{{count:ranked}} authors contributed this month"}}}
```

### Example 4: Multi-Fetch with Join

**Question**: "Top contributor's recent commits"

**Architect emits**:
```clojure
{:query
  {:fetch [{:tool :get_author_stats :as :authors :params {:since "1 month ago"}}]
   :transform [{:op :sort :on :authors :as :ranked :by :count :order :desc}
               {:op :first :on :ranked :as :top}]
   :return {:step_result {:top_contributor "{{top:author}}"}}}}
```

Then in step 2:
```clojure
{:query
  {:fetch [{:tool :get_commits :as :commits
            :params {:since "1 month ago" :author "{{resolved:top_contributor}}"}}]
   :transform [{:op :filter :on :commits :as :interesting
                :where [:or [:> :files 5] [:contains :message "refactor"]]}]
   :return {:findings :interesting
            :summary "{{resolved:top_contributor}} had {{count:interesting}} interesting commits"}}}
```

---

## Intent Escape Hatch

When the DSL can't express complex logic, fall back to natural language intent:

```clojure
{:intent "Get commits from last week. For each commit, calculate a 'risk score'
          as (deletions * 2 + additions). Group by author and sum their risk scores.
          Return the top 3 riskiest authors with their total risk and commit count."}
```

The **LLM Compiler** converts this to PTC-Lisp:

```clojure
(def commits (tool/get_commits {:since "1 week ago"}))
(def with_risk
  (map (fn [c] (assoc c :risk (+ (* (:deletions c) 2) (:additions c)))) commits))
(def by_author (group-by :author with_risk))
(def author_risks
  (map (fn [[author commits]]
         {:author author
          :total_risk (reduce + (map :risk commits))
          :commit_count (count commits)})
       by_author))
(def top3 (take 3 (sort-by :total_risk > author_risks)))
(return {:findings top3 :summary "Top 3 riskiest authors"})
```

### When to Use Intent vs Query

| Use Query DSL | Use Intent |
|---------------|------------|
| Standard CRUD operations | Custom scoring/ranking logic |
| Filter/sort/group | Complex conditionals |
| Simple aggregations | Multi-step calculations |
| Joins on single field | Fuzzy matching |
| Template summaries | Dynamic narrative generation |

---

## Agent Specifications

### 1. Architect (runs once at start)

**Purpose**: Analyze question, decide strategy, emit query/intent/plan

**Input Context**:
```
;; === original question (North Star) ===
data/original_question    ; "interesting commits from most active contributor last week"

;; === available tools ===
data/tool_summary
;; - get_commits(since?, until?, author?, limit?) -> commit list
;; - get_author_stats(since?, until?) -> author contribution counts
;; - get_file_stats(since?, limit?) -> most changed files

;; === query DSL reference (abbreviated) ===
data/dsl_reference
;; fetch: [{:tool :name :as :binding :params {...}}]
;; transform ops: filter, sort, take, drop, map, group, aggregate, join, first, last
;; return: {:findings :binding :summary "template with {{var}}"}
```

**Output Options**:

*Option A: Query DSL (simple/medium queries)*
```clojure
(return {:mode :query
         :query {:fetch [...] :transform [...] :return {...}}})
```

*Option B: Intent (complex logic)*
```clojure
(return {:mode :intent
         :intent "Natural language description of the computation..."})
```

*Option C: Plan (multi-step with dependencies)*
```clojure
(return {:mode :plan
         :steps [{:id 1 :goal "..." :needs []}
                 {:id 2 :goal "..." :needs [1]}]})
```

**Decision Guide for Architect**:
- Single tool + filter/sort → `:query`
- Custom scoring, complex conditions → `:intent`
- Results from step N needed in step N+1 → `:plan`

---

### 2. Compiler (deterministic or LLM)

**Purpose**: Convert query/intent to executable PTC-Lisp

```
┌─────────────┐
│  Architect  │
│   output    │
└──────┬──────┘
       │
       ├── {:mode :query ...}  ───▶ DSL Compiler (Elixir, deterministic)
       │                              │
       │                              ▼
       │                         PTC-Lisp code
       │
       └── {:mode :intent ...} ───▶ LLM Compiler (single-shot)
                                      │
                                      ▼
                                 PTC-Lisp code
```

**DSL Compiler** (Elixir module):
```elixir
defmodule GitQuery.Compiler do
  def compile(%{mode: :query, query: query}) do
    code = [
      compile_fetch(query.fetch),
      compile_transforms(query.transform),
      compile_return(query.return)
    ] |> Enum.join("\n")

    {:ok, code}
  end

  defp compile_fetch(fetches) do
    Enum.map(fetches, fn %{tool: tool, as: binding, params: params} ->
      "(def #{binding} (tool/#{tool} #{encode_params(params)}))"
    end)
  end

  # ... etc
end
```

**LLM Compiler** (for intent):
```
Input:
  original_question: "..."
  intent: "Get commits, calculate risk score..."
  tool_signatures: [...]

Output:
  Pure PTC-Lisp code that implements the intent
```

---

### 3. Fetcher (runs per plan step, max_turns: 1)

**Purpose**: Acquire data by calling tools. No analysis, no exploration.

**Input Context**:
```
;; === North Star (always present) ===
data/original_question    ; "interesting commits from most active contributor last week"

;; === tools ===
tool/get_commits(...)
tool/get_author_stats(...)

;; === current goal ===
data/current_goal    ; "find most active contributor last week"

;; === resolved from previous steps ===
data/resolved        ; {} or {:top_contributor "alice"}

;; === hints from Evaluator (if retry) ===
data/fetch_hints     ; ["need author stats with date filter"]

;; === DSL reference ===
data/dsl_reference   ; (same as Architect)
```

**Expected Output** (query or intent):
```clojure
(return {:mode :query
         :query {:fetch [{:tool :get_author_stats
                          :as :authors
                          :params {:since "1 week ago"}}]}})
```

The Fetcher emits a query, which the Compiler converts to tool calls.

---

### 4. Evaluator (runs after Fetcher, max_turns: 1)

**Purpose**: Transform data AND decide next action.

**Input Context**:
```
;; === North Star (always present) ===
data/original_question    ; "interesting commits from most active contributor last week"

;; === plan state ===
data/plan              ; {:steps [...] :current 0}
data/current_goal      ; "find most active contributor last week"
data/resolved          ; {}

;; === raw data from Fetcher ===
data/authors           ; [{:author "alice" :count 15} {:author "bob" :count 8}]

;; === DSL reference ===
data/dsl_reference
```

**Expected Output** (query + decision):
```clojure
(return {:mode :query
         :query {:transform [{:op :sort :on :authors :as :ranked :by :count :order :desc}
                             {:op :first :on :ranked :as :top}]
                 :return {:action :advance
                          :result {:top_contributor "{{top:author}}"}}}})
```

Or for final answer:
```clojure
(return {:mode :query
         :query {:transform [{:op :filter :on :commits :as :interesting
                              :where [:> :files 5]}
                             {:op :sort :on :interesting :as :ranked :by :files :order :desc}]
                 :return {:action :done
                          :findings :ranked
                          :summary "{{resolved:top_contributor}} had {{count:interesting}} notable commits"}}})
```

---

## Control Flow

### Main Entry Point

```elixir
def run(question, tools) do
  ctx = Context.new(
    original_question: question,
    tool_summary: summarize_tools(tools),
    dsl_reference: dsl_reference()
  )

  # Phase 1: Architect decides strategy
  case Architect.run(ctx) do
    {:query, query} ->
      # Fast path: compile and execute
      execute_query(query, ctx)

    {:intent, intent} ->
      # LLM compiles intent to code
      code = LLMCompiler.compile(intent, ctx)
      execute_code(code, ctx)

    {:plan, steps} ->
      # Complex path: run Fetcher → Evaluator loop
      ctx
      |> Context.set_plan(steps)
      |> execute_loop()
  end
end
```

### Query Execution

```elixir
defp execute_query(query, ctx) do
  with {:ok, code} <- Compiler.compile(query),
       {:ok, result} <- Sandbox.run(code, ctx) do
    result
  else
    {:error, reason} ->
      # Optionally invoke Refiner
      handle_error(reason, query, ctx)
  end
end
```

### Execution Loop (Plan Mode)

```elixir
defp execute_loop(ctx) do
  # Fetcher emits query for data acquisition
  {:query, fetch_query} = Fetcher.run(ctx)
  {:ok, fetch_code} = Compiler.compile(fetch_query)
  ctx = Sandbox.run(fetch_code, ctx)

  # Evaluator emits query for transform + decision
  {:query, eval_query} = Evaluator.run(ctx)
  {:ok, eval_code} = Compiler.compile(eval_query)

  case Sandbox.run(eval_code, ctx) do
    %{action: :done} = result ->
      result

    %{action: :advance, result: step_result} ->
      ctx
      |> Context.store_result(step_result)
      |> Context.next_step()
      |> execute_loop()

    %{action: :fetch, hints: hints} ->
      ctx
      |> Context.set_fetch_hints(hints)
      |> execute_loop()

    %{action: :revise, changes: changes} ->
      ctx
      |> Context.revise_plan(changes)
      |> execute_loop()
  end
end
```

---

## Tiered Complexity

```
┌────────────────────────────────────────────────────────────────┐
│                         Architect                               │
│  Analyzes question, chooses execution mode                     │
└───────────┬─────────────────────┬────────────────────┬─────────┘
            │                     │                    │
            ▼                     ▼                    ▼
      ┌──────────┐         ┌───────────┐        ┌───────────┐
      │  Simple  │         │  Medium   │        │  Complex  │
      │ :query   │         │ :intent   │        │ :plan     │
      │ DSL only │         │ LLM compile        │ loop      │
      │ 1 LLM    │         │ 2 LLM     │        │ 3-6 LLM   │
      └──────────┘         └───────────┘        └───────────┘

Simple: "commits from last week"
  → Query DSL, deterministic compile (1 LLM call)

Medium: "rank commits by custom risk formula"
  → Intent, LLM compiles (2 LLM calls)

Complex: "commits from most active contributor"
  → Plan with steps (3-6 LLM calls)
```

---

## Use Case Walkthroughs

### Use Case 1: Simple Query (DSL Path)

**Question**: "Show commits from last week"

**Architect output**:
```clojure
{:mode :query
 :query {:fetch [{:tool :get_commits :as :commits :params {:since "1 week ago"}}]
         :return {:findings :commits
                  :summary "Found {{count:commits}} commits from last week"}}}
```

**DSL Compiler produces**:
```clojure
(def commits (tool/get_commits {:since "1 week ago"}))
(return {:findings commits
         :summary (str "Found " (count commits) " commits from last week")})
```

**Total: 1 LLM call (Architect only)**

---

### Use Case 2: Medium Query (Intent Path)

**Question**: "Rank authors by risk score (deletions×2 + additions)"

**Architect output**:
```clojure
{:mode :intent
 :intent "Get commits from last month with diff stats. Calculate risk score
          for each commit as (deletions * 2 + additions). Group by author,
          sum risk scores. Return top 5 riskiest authors."}
```

**LLM Compiler produces**:
```clojure
(def commits (tool/get_commits {:since "1 month ago"}))
(def diffs (tool/get_diff_stats {:commits (map :hash commits)}))
(def with_risk
  (map (fn [c]
         (let [d (get diffs (:hash c))]
           (assoc c :risk (+ (* (:deletions d) 2) (:additions d)))))
       commits))
(def by_author (group-by :author with_risk))
(def author_risks
  (map (fn [[author cs]]
         {:author author :total_risk (reduce + (map :risk cs))})
       by_author))
(def top5 (take 5 (sort-by :total_risk > author_risks)))
(return {:findings top5 :summary "Top 5 riskiest authors by commit impact"})
```

**Total: 2 LLM calls (Architect + LLM Compiler)**

---

### Use Case 3: Complex Query (Plan Path)

**Question**: "Interesting commits from the most active contributor last week"

**Architect output**:
```clojure
{:mode :plan
 :steps [{:id 1 :goal "find most active contributor last week" :needs []}
         {:id 2 :goal "find interesting commits by that contributor" :needs [1]}]}
```

#### Cycle 1 (Step 1)

**Fetcher output**:
```clojure
{:mode :query
 :query {:fetch [{:tool :get_author_stats :as :authors :params {:since "1 week ago"}}]}}
```

**Evaluator output**:
```clojure
{:mode :query
 :query {:transform [{:op :sort :on :authors :as :ranked :by :count :order :desc}
                     {:op :first :on :ranked :as :top}]
         :return {:action :advance
                  :result {:top_contributor "{{top:author}}"}}}}
```

#### Cycle 2 (Step 2)

**Fetcher output**:
```clojure
{:mode :query
 :query {:fetch [{:tool :get_commits :as :commits
                  :params {:since "1 week ago"
                           :author "{{resolved:top_contributor}}"}}]}}
```

**Evaluator output**:
```clojure
{:mode :query
 :query {:transform [{:op :filter :on :commits :as :interesting
                      :where [:or [:> :files 5]
                                  [:contains :message "refactor"]
                                  [:contains :message "fix"]]}
                     {:op :sort :on :interesting :as :ranked :by :files :order :desc}]
         :return {:action :done
                  :findings :ranked
                  :summary "{{resolved:top_contributor}} made {{count:interesting}} notable commits"}}}
```

**Total: 1 Architect + 2 Fetcher + 2 Evaluator = 5 LLM calls**

All queries compiled deterministically - no LLM Compiler needed.

---

## Context Memory Layout

```
context/
├── original_question    ; "interesting commits from last week" (NEVER removed)
├── tool_summary         ; High-level tool descriptions
├── dsl_reference        ; Query DSL documentation for agents
│
├── plan/
│   ├── steps            ; [{:id :goal :needs :status :result}]
│   └── current          ; Index of current step
│
├── resolved/            ; Results from completed steps (template accessible)
│   ├── top_contributor  ; "alice"
│   └── commit_count     ; 15
│
├── data/                ; Raw tool results (current cycle)
│   ├── commits
│   ├── authors
│   └── diffs
│
└── hints/               ; Guidance for retry (cleared after use)
    ├── fetch            ; ["need diffs for risk assessment"]
    └── evaluate         ; ["focus on deletions"]
```

---

## Compiler Implementation

### DSL Compiler (Elixir)

```elixir
defmodule GitQuery.Compiler do
  @moduledoc "Deterministic Query DSL to PTC-Lisp compiler"

  def compile(%{query: query}) do
    lines = []
    |> add_fetch(query[:fetch])
    |> add_transforms(query[:transform])
    |> add_return(query[:return])

    {:ok, Enum.join(lines, "\n")}
  end

  defp add_fetch(lines, nil), do: lines
  defp add_fetch(lines, fetches) do
    fetch_lines = Enum.map(fetches, fn f ->
      params = encode_map(f.params)
      "(def #{f.as} (tool/#{f.tool} #{params}))"
    end)
    lines ++ fetch_lines
  end

  defp add_transforms(lines, nil), do: lines
  defp add_transforms(lines, transforms) do
    Enum.reduce(transforms, lines, &compile_transform/2)
  end

  defp compile_transform(%{op: :filter, on: on, as: as, where: pred}, lines) do
    pred_code = compile_predicate(pred)
    lines ++ ["(def #{as} (filter (fn [x] #{pred_code}) #{on}))"]
  end

  defp compile_transform(%{op: :sort, on: on, as: as, by: field, order: order}, lines) do
    comparator = if order == :desc, do: ">", else: "<"
    lines ++ ["(def #{as} (sort-by :#{field} #{comparator} #{on}))"]
  end

  defp compile_transform(%{op: :first, on: on, as: as}, lines) do
    lines ++ ["(def #{as} (first #{on}))"]
  end

  # ... more transform compilers

  defp compile_predicate([:>, field, value]) do
    "(> (:#{field} x) #{value})"
  end

  defp compile_predicate([:contains, field, substr]) do
    "(str-contains? (:#{field} x) \"#{substr}\")"
  end

  defp compile_predicate([:or | preds]) do
    compiled = Enum.map(preds, &compile_predicate/1)
    "(or #{Enum.join(compiled, " ")})"
  end

  # ... more predicate compilers

  defp add_return(lines, ret) do
    return_map = compile_return_map(ret)
    lines ++ ["(return #{return_map})"]
  end
end
```

### Template Resolution

```elixir
defmodule GitQuery.Template do
  @doc "Resolve {{var}} and {{count:var}} in strings"

  def resolve(template, bindings) do
    template
    |> resolve_counts(bindings)
    |> resolve_field_access(bindings)
    |> resolve_simple(bindings)
  end

  defp resolve_counts(s, bindings) do
    Regex.replace(~r/\{\{count:(\w+)\}\}/, s, fn _, var ->
      "(count #{var})"
    end)
  end

  defp resolve_field_access(s, bindings) do
    Regex.replace(~r/\{\{(\w+):(\w+)\}\}/, s, fn _, var, field ->
      "(:#{field} #{var})"
    end)
  end

  defp resolve_simple(s, bindings) do
    Regex.replace(~r/\{\{(\w+)\}\}/, s, fn _, var ->
      var
    end)
  end
end
```

---

## Cost Analysis

| Query Type | Path | LLM Calls | Compiler |
|------------|------|-----------|----------|
| Simple | Query DSL | 1 | Deterministic |
| Medium | Intent | 2 | LLM |
| Two-step plan | Query DSL | 5 | Deterministic |
| Complex plan | Mixed | 5-7 | Both |

**Benefits of DSL approach**:
- No syntax errors from LLM (DSL is structured)
- Deterministic compilation is fast
- Intent is explicit and debuggable
- LLM only used when truly needed

---

## Implementation Checklist

- [ ] Query DSL schema definition
- [ ] DSL Compiler (Elixir) - fetch, transform, return
- [ ] Template resolver for `{{var}}` syntax
- [ ] Architect agent with query/intent/plan output modes
- [ ] Fetcher agent emitting queries
- [ ] Evaluator agent emitting queries + decisions
- [ ] LLM Compiler for intent escape hatch
- [ ] Control loop with tiered execution paths
- [ ] DSL reference documentation for agent context

---

## Open Questions

1. **DSL extensibility?** How to add new transform ops without breaking existing queries?

2. **Validation?** Should we validate queries before compilation? (schema check)

3. **Error messages?** When DSL compilation fails, what feedback to give the agent?

4. **Caching?** Cache compiled code for repeated query patterns?

5. **DSL in context?** How much DSL documentation to include in agent context without bloating it?
