# Function Passing Between SubAgents

## Problem

In the recursive RLM pattern (`tools: %{"search" => :self}`), each child agent gets its own LLM call that generates a fresh PTC-Lisp program. No function definitions are shared across recursion levels — each child starts with an empty `user_ns`.

This means if the parent generates helpers like `parse-profile` and `shared-hobbies?`, every child regenerates very similar functions from scratch. This wastes tokens, increases latency, and introduces inconsistency (children may define slightly different versions).

Example from OOLONG-Pairs benchmark — the parent generates:

```clojure
(defn parse-profile [s]
  (let [id (extract-int #"PROFILE (\d+):" s)
        name (extract #"name=([^,]+)" s)
        city (extract #"city=([^,]+)" s)
        hobbies (re-split #", " (extract #"\[(.+?)\]" s))]
    {:id id :name name :city city :hobbies (set hobbies)}))

(defn shared-hobbies? [p1 p2]
  (some #(contains? (:hobbies p2) %) (:hobbies p1)))
```

Each child then regenerates these same helpers, burning ~200 tokens per child on redundant code generation.

## Existing Infrastructure

PTC-Lisp already has the machinery for closure serialization, used in the Alma example:

- **`CoreToSource.serialize_closure/1`** — converts a closure tuple to PTC-Lisp source string by extracting params + body (drops captured env)
- **`CoreToSource.export_namespace/1`** — serializes an entire `user_ns` as topologically sorted `(def ...)` forms, handling dependency ordering
- **Hydration** — `Lisp.run(source)` reconstructs closures from source strings

The roundtrip is proven: closure -> source string -> parse -> analyze -> eval -> closure.

## Comparison with Python RLM

The [original Python RLM](https://arxiv.org/abs/2512.24601) has the same limitation — each recursive child gets a fresh REPL namespace. No function sharing between levels. Both implementations pass only data (context/corpus), not code, from parent to child.

## Proposed Solutions

### Option A: Automatic `user_ns` propagation on `:self` calls

When a `:self` tool fires, the engine automatically:

1. Serializes the parent's `user_ns` via `export_namespace` (topo-sorted `(def ...)` forms)
2. Passes the source string as a hidden prelude to the child
3. Auto-evals it before the child LLM's first turn
4. Lists available functions in the child's prompt

The LLM doesn't manage serialization — it just defines `defn` in the parent and the children see them.

```clojure
;; Parent (depth 0) — defines helpers, then recurses
(defn parse-profile [s] ...)
(defn shared-hobbies? [p1 p2] ...)
(pmap #(tool/search {:corpus %}) chunks)

;; Child (depth 1) — parse-profile and shared-hobbies? are already available
(let [profiles (map parse-profile (split-lines data/corpus))]
  (find-pairs profiles))
```

For the top-level call (no parent), the prelude is simply empty.

**Pros:**
- Transparent to the LLM — no new syntax
- Uses existing `export_namespace` infrastructure
- Children are immediately productive

**Cons:**
- All `def`/`defn` propagate — no selective sharing
- Closures capturing local bindings (from `let`) won't serialize correctly (env is dropped)
- Parent's buggy functions propagate to all children

**Implementation scope:** Changes to `SubAgent.run` and `Loop` to thread `user_ns` through `:self` tool calls. Prompt generation needs to list inherited functions.

### Option B: Explicit prelude in agent config

A static `:prelude` option on the agent definition:

```elixir
SubAgent.new(
  tools: %{"search" => :self},
  prelude: """
  (defn parse-profile [s] ...)
  (defn shared-hobbies? [p1 p2] ...)
  """
)
```

Every recursion level auto-loads the prelude before the LLM's code runs.

**Pros:**
- Simple, predictable
- Developer controls exactly what's shared
- No serialization needed at runtime

**Cons:**
- Static — the developer must know the helpers in advance
- Defeats the purpose of LLM-generated code

**Implementation scope:** Minimal — eval prelude source before first turn in `Loop.run`.

### Option C: LLM-driven explicit passing

Add `export-ns` builtin and let the LLM decide what to pass:

```clojure
;; Parent explicitly passes its namespace
(tool/search {:corpus chunk :prelude (export-ns)})

;; Child evaluates received prelude
(eval data/prelude)
```

**Pros:**
- LLM has full control over what to share
- Works with any tool, not just `:self`

**Cons:**
- Requires new builtins: `export-ns` and `eval`
- `eval` is a security surface (though sandbox already constrains execution)
- LLM must learn to use the pattern — extra prompt complexity

**Implementation scope:** New builtins in `Env`, `eval` form in analyzer/interpreter.

### Option D: Function type in tool signatures

Extend signatures to support a `:fn` parameter type:

```elixir
signature: %{
  corpus: :string,
  compare_fn: {:fn, optional: true}
}
```

The engine serializes closures to source strings when crossing the SubAgent boundary and hydrates them on the child side. The top-level call passes `nil`.

```clojure
;; Parent passes functions as tool arguments
(tool/search {:corpus chunk :compare_fn shared-hobbies?})

;; Child uses passed function directly
(filter #(data/compare_fn (first %) (second %)) pairs)
```

**Pros:**
- Most flexible — functions are first-class across agent boundaries
- Enables higher-order agent composition patterns
- Works beyond `:self` — any tool could accept functions

**Cons:**
- Serialization/hydration adds complexity
- Closures with captured env won't roundtrip (env is dropped)
- Signature validation needs new type handling
- Child LLM must understand function args come from `data/`

**Implementation scope:** Changes to signature validation, tool call serialization in `ToolNormalizer`, hydration in child agent setup.

### Option E: Direct AST injection (recommended)

Pass closure tuples directly into the child's Lisp environment — no serialization, no string roundtrip.

PTC-Lisp closures are immutable Elixir tuples: `{:closure, params, body, env, history, meta}`. The captured `env` is a plain immutable map. These are ordinary BEAM values that copy efficiently across process boundaries with zero mutation risk.

When a `:self` tool fires, the engine:

1. Extracts the parent's `user_ns` (map of names to values, including closures)
2. Injects closure entries directly into the child's initial `user_ns`
3. Adds a prompt line: "Available functions from parent: `parse-profile`, `shared-hobbies?`"

```clojure
;; Parent (depth 0) — defines helpers, then recurses
(defn parse-profile [s] ...)
(defn shared-hobbies? [p1 p2] ...)
(pmap #(tool/search {:corpus %}) chunks)

;; Child (depth 1) — functions are already in namespace, just call them
(let [profiles (map parse-profile (split-lines data/corpus))]
  ...)
```

**Why this is the best approach:**

- **Preserves closures fully** — captured `env` comes along intact. A closure that captures a `let` binding just works. No env-dropping like `export_namespace`.
- **No serialization overhead** — no parse/analyze/eval roundtrip. The AST tuple IS the function.
- **No deadlocks** — the child executes the AST locally in its own sandbox process. `pmap` stays fully parallel.
- **Efficient data copying** — BEAM optimizes immutable structure passing between processes on the same node (large binaries are ref-counted, not copied).
- **Prompt-efficient** — the child LLM sees only function names, not implementations. It doesn't need the source code to call `parse-profile`.
- **Transparent** — no new syntax, no new builtins. Functions appear in the child's namespace like builtins.

**Implementation scope:**

1. `ToolNormalizer.wrap_sub_agent_tool/2` — when building the child's run opts, extract closures (and optionally other `def` values) from the parent's `user_ns` and pass as an `:inherited_ns` option.
2. `Loop.run/2` — merge `inherited_ns` into the child's initial `user_ns` before the first turn.
3. Prompt generation — list inherited function names (with param signatures via `CoreToSource.format_params`) so the child LLM knows what's available.
4. `Eval` — no changes needed. Inherited closures are already valid values in the namespace.

## Recommendation

**Option E** (direct AST injection) is the clear winner. It leverages Elixir's immutable data model to sidestep the serialization problem entirely. Closures with captured environments just work. Implementation is minimal — the main change is threading the parent's namespace through the `:self` tool call boundary.

Options A-D remain useful in specific contexts:
- **Option B** (static prelude) is still valuable for developer-defined shared utilities
- **Option D** (function type in signatures) is interesting for non-`:self` tools where agents from different definitions pass functions to each other

## Open Questions

1. **Selective propagation** — should all `def`/`defn` entries propagate, or only closures? Non-function `def` values (counters, intermediate results) may not make sense in children.
2. **Naming conflicts** — what if the child LLM redefines an inherited function? Override silently, or warn?
3. **Prompt format** — just names + param lists, or include docstrings? e.g., `(parse-profile [s])` vs full `@doc` strings.
4. **Non-`:self` tools** — should propagation work for any `SubAgentTool`, or only `:self`?
5. **Depth accumulation** — at depth 3, the child inherits from depth 2, which inherited from depth 1. Should the full chain propagate, or only the immediate parent's definitions?
6. **Memory namespace interaction** — `user_ns` includes both `def` values and `memory` entries. Should inherited functions live in a separate `parent/` namespace to avoid collisions?
