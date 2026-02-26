# Function Passing + LLM Query: Open-Ended Composition Patterns

How closures and `llm_query` compose together, what works today, and what could be added.

## Background

**Function passing** works via two mechanisms:
1. **Implicit inheritance** — `:self` tools auto-propagate all closures from parent memory
2. **Explicit `:fn` params** — SubAgentTool signatures declare `(items [:map], transform :fn) -> ...`

**`llm_query`** is an ad-hoc LLM judgment tool called from PTC-Lisp. It uses Mustache templating for the prompt and returns structured data.

## The Gap: Closures Can't Flow INTO `llm_query`

`llm_query` renders its prompt via Mustache, which only handles scalars. Closures can't be passed as template args — Mustache would render them as garbage. The LLM query agent is ephemeral (single-shot, `output: :text`) and doesn't run PTC-Lisp, so it can't call closures either.

## What Works Today: One-Way Composition

LLM query results flow INTO closures:

```clojure
;; Define reusable transform logic
(defn enrich [item classification]
  (assoc item :priority (:urgency classification) :tagged true))

;; Use llm-query for judgment, closure for transform
(mapv (fn [item]
        (let [cls (tool/llm-query {:prompt "Classify urgency: {{desc}}"
                                    :signature "{urgency :string, confidence :float}"
                                    :desc (:description item)})]
          (enrich item cls)))
      data/items)
```

The LLM does judgment, the closure does deterministic transformation.

## Open-Ended Patterns

### Pattern 1: LLM-Guided Function Selection

Define multiple closures, use `llm_query` to decide which one to apply:

```clojure
(defn strategy-a [x] (assoc x :action "escalate"))
(defn strategy-b [x] (assoc x :action "defer"))
(defn strategy-c [x] (assoc x :action "auto-resolve"))

(mapv (fn [ticket]
        (let [decision (tool/llm-query
                         {:prompt "Which strategy (a/b/c) for: {{summary}}"
                          :signature "{strategy :string}"
                          :summary (:summary ticket)})
              apply-fn (cond
                         (= (:strategy decision) "a") strategy-a
                         (= (:strategy decision) "b") strategy-b
                         :else strategy-c)]
          (apply-fn ticket)))
      data/tickets)
```

Keeps the LLM in the "judgment" seat while closures handle deterministic logic.

**Status:** Likely works today — closures are values in PTC-Lisp, so `cond` should be able to return them. Needs testing.

### Pattern 2: LLM Query as Closure Parameterizer

Use the LLM to generate *parameters* (data) that drive closure logic:

```clojure
;; Closure applies configurable rules
(defn apply-rules [item rules]
  (reduce (fn [acc rule]
            (if (:active rule)
              (assoc acc (:field rule) (:value rule))
              acc))
          item rules))

;; LLM generates the rules dynamically
(let [rules (tool/llm-query
              {:prompt "Generate processing rules for: {{domain}}"
               :signature "{rules [{field :string, value :string, active :bool}]}"
               :domain data/domain})]
  (mapv #(apply-rules % (:rules rules)) data/items))
```

The LLM produces *data* that drives closure logic — a form of LLM-generated configuration.

**Status:** Works today.

### Pattern 3: Inherited Functions + llm_query in Child Agents

A parent defines closures, spawns a child (`:self` tool) that inherits them AND has `llm_query: true`:

```elixir
agent = SubAgent.new(
  prompt: "Process data items, use inherited helpers and LLM judgment as needed",
  signature: "(items [:map]) -> {results [:map]}",
  tools: %{"worker" => :self},
  llm_query: true,
  max_turns: 10
)
```

The parent defines helper closures, then the child uses them combined with `llm_query` for decisions:

```clojure
;; Parent: define helpers
(defn normalize [record] (assoc record :status "normalized"))
(defn validate [record] (> (count (keys record)) 2))

;; Parent: delegate to child
(tool/worker {:items data/items})
```

```clojure
;; Child inherits normalize + validate, AND has llm-query
(mapv (fn [item]
        (let [judgment (tool/llm-query
                         {:prompt "Should we process {{name}}?"
                          :signature "{process :bool}"
                          :name (:name item)})]
          (if (:process judgment)
            (normalize item)   ;; inherited closure
            item)))
      data/items)
```

This gives recursive child agents both **inherited deterministic logic** (closures) and **ad-hoc LLM judgment** (llm_query). Children don't need to reinvent the helpers.

**Status:** Works today via `:self` inheritance + `llm_query: true`.

### Pattern 4: Closure as llm_query Post-Processor (Proposed)

Allow `llm_query` to accept a `:transform` key that's a closure applied to the result:

```clojure
(defn extract-priority [result] (:priority result))

(mapv (fn [item]
        (tool/llm-query {:prompt "Classify: {{desc}}"
                          :signature "{priority :string, reason :string}"
                          :desc (:description item)
                          :transform extract-priority}))
      data/items)
```

**Status:** Does not work today. The `:transform` key would be dropped or fail in Mustache rendering.

**Implementation:** In `wrap_builtin_llm_query`, add `:transform` to control keys. After `execute_llm_json` returns, check for a closure in the `:transform` arg, validate it, and apply it to the result. Roughly:

```elixir
# In wrap_builtin_llm_query, after execute_llm_json:
transform = Map.get(args, "transform")
result = execute_llm_json(name, tool, template_args, state)

case transform do
  {:closure, _, _, _, _, _} ->
    # Apply closure to result inside sandbox
    Sandbox.execute(fn -> apply_closure(transform, [result]) end)
  nil ->
    result
end
```

**Open question:** Is this worth adding, or is `(let [r (tool/llm-query ...)] (extract-priority r))` simple enough? The `let` approach works today with no changes.

### Pattern 5: Higher-Order Agent Factory

Combine `:fn` params with `llm_query` in a worker SubAgent — the parent passes both behavior (closure) and judgment strategy (via llm_query enablement):

```elixir
worker = SubAgent.new(
  prompt: "For each item, use LLM to decide if it matches, then apply transform_fn",
  signature: "(items [:map], transform_fn :fn) -> [:map]",
  llm_query: true,
  max_turns: 3
)

tools = %{"smart_map" => SubAgent.as_tool(worker)}
```

```clojure
;; Parent defines different transforms for different use cases
(defn uppercase-name [item] (update item :name upper-case))

;; Parent delegates: child gets both the closure AND llm judgment
(tool/smart_map {:items data/items :transform_fn uppercase-name})
```

```clojure
;; Child (smart_map) uses both:
(filterv
  (fn [item]
    (let [match (tool/llm-query {:prompt "Does {{name}} match criteria?"
                                  :signature "{match :bool}"
                                  :name (:name item)})]
      (:match match)))
  (mapv data/transform_fn data/items))  ;; closure from parent via :fn param
```

**Status:** Works today. Combines explicit `:fn` passing with `llm_query: true`.

## Summary Table

| Pattern | Works Today? | Description |
|---------|-------------|-------------|
| LLM query result → closure input | Yes | LLM judges, closure transforms |
| LLM-guided function selection | Likely (needs test) | Dynamic dispatch via cond |
| LLM as closure parameterizer | Yes | LLM generates config data for closures |
| Inherited closures + llm_query in children | Yes (`:self`) | Recursive agents with shared logic + judgment |
| Closure as llm_query post-processor | No (proposed) | Clean composability, but `let` works as alternative |
| Higher-order agent factory | Yes | `:fn` params + `llm_query` on same agent |

## Recommendation

The most impactful open-ended pattern is **Pattern 3**: `:self` recursive agents that inherit a library of closures from their parent AND use `llm_query` for ad-hoc decisions. This provides a reusable "toolkit" of deterministic functions combined with flexible LLM judgment at any depth.

**Pattern 4** (closure post-processor) is low priority since the `let` workaround is straightforward.

**Pattern 1** (LLM-guided function selection) should be tested to confirm closures work as `cond` return values in PTC-Lisp.
