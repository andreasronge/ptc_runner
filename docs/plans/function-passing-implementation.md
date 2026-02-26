# Function Passing Between SubAgents — Implementation Plan

## Design Summary

Two complementary mechanisms:

1. **Implicit inheritance for `:self` tools** — When a `:self` tool fires, all closures from the parent's `user_ns` are automatically injected into the child's starting namespace. The child's prompt lists inherited functions with signatures and docstrings.

2. **Explicit `:fn` params for non-`:self` tools** — Tool signatures can declare parameters of type `:fn`. The parent LLM passes specific closures as tool arguments. The child receives them in `data/` and its prompt shows the function contract (name, params, docstring).

Both use **direct AST injection** (Option E) — closure tuples pass through as-is, no serialization roundtrip.

## Docstring Convention

PTC-Lisp already supports Clojure-style docstrings:

```clojure
(defn parse-profile
  "Extracts id, name, city, and hobbies from a profile string."
  [s]
  ...)
```

The docstring flows through: Parser → Analyzer (stored in `{:def, name, expr, %{docstring: "..."}}`) → Eval (`merge_docstring_into_closure/2`) → closure metadata `%{docstring: "..."}`.

The `Namespace.User` module already renders docstrings:
```
(parse-profile [s])          ; "Extracts id, name, city, and hobbies from a profile string."
```

This existing infrastructure is reused for both implicit and explicit passing. No changes to docstring handling needed.

---

## Phase 1: Implicit Inheritance for `:self` Tools

### Step 1.1: Detect `:self` tools and pass parent memory

**File**: `lib/ptc_runner/sub_agent/loop/tool_normalizer.ex`
**Function**: `wrap_sub_agent_tool/3`

Currently the wrapped function builds `run_opts` with `context: args` but no memory. We need to:

1. Add a `is_self_tool?` check: compare `tool.agent` to the parent `agent` (passed via `state`). The `resolve_self_tools/2` in `SubAgent` stores the same agent struct reference, so identity comparison works. We need to pass the parent agent into `state` (or into `wrap_sub_agent_tool`).

2. When `is_self_tool?` is true, extract closures from `state.memory` and add `:inherited_ns` to `run_opts`.

**Changes**:

```elixir
# In wrap_sub_agent_tool/3:
def wrap_sub_agent_tool(name, %SubAgentTool{} = tool, state) do
  fn args ->
    resolved_llm = tool.agent.llm || tool.bound_llm || state.llm

    # Extract closures from parent memory for :self tools
    inherited_ns =
      if self_tool?(tool, state) do
        extract_closures(state.memory)
      else
        nil
      end

    run_opts =
      [
        llm: resolved_llm,
        llm_registry: state.llm_registry,
        context: args,
        _nesting_depth: state.nesting_depth + 1,
        _remaining_turns: state.remaining_turns,
        _mission_deadline: state.mission_deadline
      ]
      |> maybe_add_opt(:max_heap, state[:max_heap])
      |> maybe_add_opt(:_inherited_ns, inherited_ns)

    # ... rest unchanged (trace handling)
  end
end

# Detection: :self tools have tool.agent matching the parent agent
defp self_tool?(%SubAgentTool{agent: child_agent}, state) do
  state[:parent_agent] != nil and state[:parent_agent] == child_agent
end

# Extract only closure tuples from memory, excluding internal keys
defp extract_closures(memory) when is_map(memory) do
  memory
  |> Enum.filter(fn
    {name, {:closure, _, _, _, _, _}} ->
      name_str = Atom.to_string(name)
      not String.starts_with?(name_str, "_") and not String.starts_with?(name_str, "__ptc_")
    _ -> false
  end)
  |> Map.new()
end

defp extract_closures(_), do: %{}
```

**Prerequisite**: The `state` map needs a `:parent_agent` key so we can detect `:self` tools. This is set in `Loop.run` when building `initial_state`.

### Step 1.2: Thread `parent_agent` into state

**File**: `lib/ptc_runner/sub_agent/loop.ex`
**Function**: `do_run/2` (line 236)

Add `:parent_agent` to `initial_state`:

```elixir
initial_state = %{
  # ... existing fields ...
  memory: %{},
  parent_agent: agent,  # NEW: for self-tool detection in ToolNormalizer
  # ...
}
```

This is the agent struct passed to `Loop.run/2`. When `resolve_self_tools` runs, it stores this same struct in `SubAgentTool.agent`, so the comparison `state.parent_agent == tool.agent` will match.

### Step 1.3: Accept and merge `inherited_ns` in Loop

**File**: `lib/ptc_runner/sub_agent/loop.ex`

**Three changes needed:**

#### 1.3a: Extract `_inherited_ns` from opts (line ~143)

In `Loop.run/2`, where other `_`-prefixed options are extracted:

```elixir
# After: journal = Keyword.get(opts, :journal)
inherited_ns = Keyword.get(opts, :_inherited_ns, %{}) || %{}
```

#### 1.3b: Add to `run_opts` struct (line ~171-191)

```elixir
run_opts = %{
  # ... existing fields ...
  inherited_ns: inherited_ns
}
```

#### 1.3c: Merge into initial_state in `do_run/2` (line ~236)

```elixir
initial_state = %{
  # ... existing fields ...
  memory: run_opts.inherited_ns,   # WAS: %{} — now seeded with parent closures
  inherited_ns: run_opts.inherited_ns,  # Track what was inherited (for prompt rendering)
  # ...
}
```

We store `inherited_ns` separately so the prompt renderer can distinguish inherited functions from self-defined ones. The `inherited_ns` key is **immutable** — it's set once at agent start and never updated. It tells the renderer which names were inherited vs self-defined.

**Important**: `inherited_ns` must NOT be updated in `build_continuation_state/5` — it stays constant across all turns of the child agent.

### Step 1.4: Render inherited functions in prompt

**File**: `lib/ptc_runner/sub_agent/namespace/user.ex`

Currently renders all memory under `";; === user/ (your prelude) ==="`. We need to:

1. Accept an `:inherited_ns` option (map of inherited closure names)
2. Split functions into "inherited" and "self-defined" groups
3. Render inherited functions under a separate header

**New rendering format**:

```
;; === user/ (inherited) ===
(parse-profile [s])          ; "Extracts id, name, city, and hobbies."
(shared-hobbies? [p1 p2])   ; "Check if two profiles share hobbies."

;; === user/ (your prelude) ===
(my-helper [x])
total                        ; = integer, sample: 42
```

When there are no self-defined entries, only the inherited section shows. When there are no inherited entries (turn 1 of root agent), behavior is unchanged.

**Changes to `render/2`**:

```elixir
def render(memory, opts) do
  inherited_ns = Keyword.get(opts, :inherited_ns, %{})
  {inherited_fns, own_memory} = split_inherited(memory, inherited_ns)

  inherited_section = render_inherited(inherited_fns)
  own_section = render_own(own_memory, opts)

  case {inherited_section, own_section} do
    {nil, nil} -> nil
    {inh, nil} -> inh
    {nil, own} -> own
    {inh, own} -> inh <> "\n\n" <> own
  end
end

defp split_inherited(memory, inherited_ns) when map_size(inherited_ns) == 0 do
  {[], memory}
end

defp split_inherited(memory, inherited_ns) do
  inherited_names = MapSet.new(Map.keys(inherited_ns))

  {inherited, own} =
    Enum.split_with(memory, fn {name, _} -> MapSet.member?(inherited_names, name) end)

  {inherited, Map.new(own)}
end
```

### Step 1.5: Thread `inherited_ns` through prompt generation

**Four call sites** that call `Namespace.render` need to pass `inherited_ns`:

#### 1.5a: `Namespace.render/1` (lib/ptc_runner/sub_agent/namespace.ex)

Add `inherited_ns` to `user_opts` and pass through:

```elixir
user_opts = [
  has_println: config[:has_println] || false,
  inherited_ns: config[:inherited_ns] || %{}    # NEW
] ++ sample_opts
```

#### 1.5b: `SystemPrompt.generate_context/2` (lib/ptc_runner/sub_agent/system_prompt.ex, lines 214 and 396)

These render namespace for the first user message. On first turn, `memory: %{}` is correct. But for a child agent with inherited_ns, the inherited closures ARE in memory on turn 1. Pass `inherited_ns` through:

```elixir
Namespace.render(%{
  tools: tools,
  data: context,
  field_descriptions: all_field_descriptions,
  context_signature: context_signature,
  memory: %{},
  inherited_ns: opts[:inherited_ns] || %{},  # NEW
  has_println: false
})
```

The `opts` for `generate_context` need a new `:inherited_ns` key, threaded from `build_first_user_message`.

#### 1.5c: `build_first_user_message/3` in Loop (line 1051)

Thread `inherited_ns` from `run_opts` into `SystemPrompt.generate_context`:

```elixir
context_prompt =
  SystemPrompt.generate_context(agent,
    context: run_opts.context,
    received_field_descriptions: run_opts.received_field_descriptions,
    inherited_ns: run_opts.inherited_ns   # NEW
  )
```

**Wait** — but the first user message is built BEFORE `initial_state`, so inherited closures aren't in `memory: %{}` at that point. We need to pass inherited_ns to the initial `Namespace.render` call so it appears in the first turn's prompt.

Actually, looking more carefully: `build_first_user_message` uses `memory: %{}` always (turn 1 has no self-defined memory). The inherited functions should appear in the user/ section even on turn 1. So we need to either:
- Pass `memory: inherited_ns` in the first turn's Namespace.render, OR
- Pass `inherited_ns` separately and let User.render handle it

The cleaner approach: pass `memory: run_opts.inherited_ns` in the first `Namespace.render` call, AND pass `inherited_ns: run_opts.inherited_ns` so the renderer knows they're all inherited (not self-defined).

#### 1.5d: Compression (lib/ptc_runner/sub_agent/compression/single_user_coalesced.ex, line 109)

The compression strategy rebuilds the single user message on turn 2+. It calls `Namespace.render` with `memory:` from the accumulated state. It needs `inherited_ns` too:

```elixir
Namespace.render(%{
  tools: tools,
  data: data,
  memory: memory,
  inherited_ns: opts[:inherited_ns] || %{},  # NEW
  has_println: has_println,
  sample_limit: sample_limit,
  sample_printable_limit: sample_printable_limit
})
```

The compression opts are built in `build_compressed_messages` (loop.ex line 1109). Add:
```elixir
|> Keyword.put(:inherited_ns, state.inherited_ns)
```

### Step 1.7: Naming conflicts — child overrides silently

If the child LLM writes `(defn parse-profile ...)`, it overrides the inherited version. This is natural — it mirrors lexical scoping where inner bindings shadow outer ones. The child's `(def ...)` updates `user_ns` which already contains the inherited entry, so `Map.put` naturally overrides.

No code change needed — this is the default behavior.

### Step 1.8: Depth accumulation — full chain propagates

At depth 2, the child's `state.memory` contains both inherited closures (from depth 0) and its own definitions (from depth 1). When it spawns a depth-3 child via `:self`, `extract_closures(state.memory)` captures everything. This is the correct behavior — deeper children see all accumulated definitions.

No special code needed — it falls out naturally from merging inherited into memory.

---

## Phase 2: Explicit `:fn` Params for Non-`:self` Tools

### Step 2.1: Add `:fn` type to signature parser

**File**: `lib/ptc_runner/sub_agent/signature/parser.ex`

Add `:fn` as a recognized type keyword:

```elixir
# In type_keyword combinator, add to the choice list:
type_keyword =
  ignore(ascii_char([?:]))
  |> choice([
    string("string"),
    string("int"),
    string("float"),
    string("bool"),
    string("keyword"),
    string("map"),
    string("fn"),      # NEW
    string("any")
  ])
  |> map({String, :to_atom, []})
```

Also add `"fn"` to `@valid_types`:

```elixir
@valid_types ~w(string int float bool keyword map fn any)
```

This allows signatures like:
```
(data :list, mapper_fn :fn) -> [:string]
(corpus :string, compare_fn :fn?) -> {count :int}
```

### Step 2.2: Add `:fn` to Signature type spec

**File**: `lib/ptc_runner/sub_agent/signature.ex`

```elixir
@type type ::
        :string
        | :int
        | :float
        | :bool
        | :keyword
        | :any
        | :map
        | :fn           # NEW
        | {:optional, type()}
        | {:list, type()}
        | {:map, [field()]}
```

### Step 2.3: Validate `:fn` params as closures

**File**: `lib/ptc_runner/sub_agent/signature/validator.ex`

Add validation for `:fn` type that checks the value is a closure tuple:

```elixir
def validate(value, :fn) do
  case value do
    {:closure, _, _, _, _, _} -> :ok
    nil -> :ok  # Optional fn params may be nil
    _ -> {:error, [%{path: [], message: "expected fn (closure), got #{type_name(value)}"}]}
  end
end
```

### Step 2.4: Render closures in `data/` namespace

**File**: `lib/ptc_runner/sub_agent/namespace/data.ex`

When a `data/` value is a closure, render it with its signature and docstring instead of showing "closure" as a type:

```elixir
defp format_entry(name, {:closure, params, _, _, _, meta} = _closure, _param_types, _field_descriptions, _opts) do
  name_str = to_string(name)
  params_str = format_closure_params(params)
  padded_name = String.pad_trailing("data/#{name_str}", @name_width)

  docstring = Map.get(meta, :docstring)

  doc_part = if docstring, do: " -- #{docstring}", else: ""

  "#{padded_name}; fn [#{params_str}]#{doc_part}"
end
```

This produces:
```
;; === data/ ===
data/corpus                   ; string, sample: "PROFILE 1: ..."
data/mapper_fn                ; fn [line] -- Extracts timestamp and error code from a log line.
```

The child LLM sees exactly the contract it needs: `data/mapper_fn` is callable with one argument `[line]`, and the docstring explains what it does.

### Step 2.5: Skip closure serialization in tool call args

When a parent LLM calls `(tool/map-reduce {:data my-list :mapper_fn parse-log})`, the `parse-log` value resolves to a closure tuple in the Lisp evaluator. This tuple flows into the tool call args map.

Currently, `ToolNormalizer.wrap_sub_agent_tool` passes `context: args` directly. The closure tuple is a valid Elixir value, so it passes through without issue. The child's `Lisp.run` receives it in the context map, and `data/mapper_fn` resolves to the closure.

**No change needed** in the tool call pipeline — closures are just values.

### Step 2.6: Closures are already callable from `data/` namespace — VERIFIED

**No changes needed.** The evaluation chain works end-to-end:

1. `(data/mapper_fn item)` parses as `{:call, {:data, :mapper_fn}, [args...]}`
2. `do_eval({:data, key}, eval_ctx)` (eval.ex line 186) resolves to the closure tuple via `flex_get(ctx, key)`
3. `do_eval({:call, ...})` (eval.ex line 361) evaluates the operator and args, then calls `Apply.apply_fun/4`
4. `Apply.do_apply_fun({:closure, patterns, ...}, args, ...)` (apply.ex line 79-89) matches the closure pattern, checks arity, and calls `execute_closure`

This is the same path used for `let`-bound closures and `user_ns` closures. Verified by reading apply.ex lines 78-89.

### Step 2.7: JSON Schema for `:fn` type

**File**: `lib/ptc_runner/sub_agent/signature.ex`

The `:fn` type doesn't map to JSON Schema (it's a runtime-only type for inter-agent communication). For LLM-facing tool schemas, `:fn` params should be excluded or rendered as `:any`:

```elixir
def type_to_json_schema(:fn), do: %{"type" => "string"}
# Or exclude :fn params from JSON schema generation entirely
```

This only matters if signatures are converted to JSON Schema for external LLM tool-use. For PTC-Lisp agents, signatures are rendered as text, not JSON Schema.

### Step 2.8: Signature renderer for `:fn` type

**File**: `lib/ptc_runner/sub_agent/signature/renderer.ex`

Add rendering for `:fn`:

```elixir
def render_type(:fn), do: ":fn"
```

---

## Phase 3: Testing

### Integration Tests for Phase 1

**File**: `test/ptc_runner/sub_agent/inherited_ns_test.exs`

1. **Basic inheritance**: Parent defines `(defn double [x] (* x 2))`, calls `:self` tool. Child can call `(double 5)` and get `10`.

2. **Docstring visibility**: Parent defines function with docstring. Verify the child's prompt contains the docstring in the inherited section.

3. **Only closures propagate**: Parent defines `(def count 5)` and `(defn f [x] x)`. Only `f` appears in child's `inherited_ns`.

4. **Child override**: Child redefines an inherited function. Verify the child's version is used.

5. **Depth accumulation**: Depth 0 defines `f`, depth 1 defines `g`, depth 2 sees both `f` and `g`.

6. **Internal keys filtered**: `(def _internal 1)` and `(def __ptc_foo 1)` are not inherited.

7. **Non-`:self` SubAgentTool does NOT inherit**: A `SubAgentTool` wrapping a different agent does not receive implicit inheritance.

### Integration Tests for Phase 2

**File**: `test/ptc_runner/sub_agent/fn_param_test.exs`

1. **Signature parsing**: `"(data :list, mapper :fn) -> [:string]"` parses correctly.

2. **Optional fn param**: `"(data :list, filter :fn?) -> [:string]"` — `nil` passes validation.

3. **Closure validation**: Passing a non-closure value for a `:fn` param fails validation.

4. **Prompt rendering**: Closure in `data/` renders with `fn [params]` format and docstring.

5. **Callable from data/**: Child can call `(data/mapper_fn item)` when `mapper_fn` is a closure.

### Unit Tests

1. `extract_closures/1` — filters correctly
2. `self_tool?/2` — detection works
3. `Namespace.User.render/2` — inherited section rendering
4. `Namespace.Data` — closure entry rendering
5. Signature parser — `:fn` type parsing

---

## File Change Summary

| File | Phase | Change |
|------|-------|--------|
| `lib/ptc_runner/sub_agent/loop/tool_normalizer.ex` | 1 | Add `self_tool?`, `extract_closures`, pass `_inherited_ns` |
| `lib/ptc_runner/sub_agent/loop.ex` | 1 | Add `parent_agent` to state, merge `inherited_ns` into initial memory, thread through prompt |
| `lib/ptc_runner/sub_agent/namespace/user.ex` | 1 | Split inherited vs own functions, render with separate headers |
| `lib/ptc_runner/sub_agent/namespace.ex` | 1 | Pass `inherited_ns` option through |
| `lib/ptc_runner/sub_agent/signature/parser.ex` | 2 | Add `:fn` to type choices |
| `lib/ptc_runner/sub_agent/signature.ex` | 2 | Add `:fn` to type spec, JSON schema |
| `lib/ptc_runner/sub_agent/signature/validator.ex` | 2 | Validate `:fn` as closure |
| `lib/ptc_runner/sub_agent/signature/renderer.ex` | 2 | Render `:fn` type |
| `lib/ptc_runner/sub_agent/namespace/data.ex` | 2 | Render closure entries with signature+docstring |

---

## Key Safety Invariants

### Prompt rendering never leaks closure source code

The `Namespace.User` renderer only extracts **metadata** from closures:
- `get_docstring/1` — reads `meta.docstring` (6th tuple element)
- `get_return_type/1` — reads `meta.return_type` (6th tuple element)
- `format_params/1` — reads `params` (2nd tuple element) and formats parameter names

It **never** calls `CoreToSource.serialize_closure/1` or accesses the `body` (3rd element) or `env` (4th element). The prompt sees `(parse-profile [s]) ; "docstring"` — not the implementation.

Similarly, `Namespace.Data` for Phase 2 will render closures as `data/mapper_fn ; fn [line] -- docstring` without touching the body or env.

The `inherited_ns` keys in state serve as a **rendering hint only** — they tell `User.render` which functions are inherited (render as signature-only) vs self-defined (render normally with samples for values). The actual execution happens through `state.memory` which contains the full closure tuples.

### Closure AST tuples are immutable

BEAM immutability guarantees that the parent's closure tuples cannot be mutated by the child. The child gets a copy (or ref-counted share for large binaries). If the child redefines an inherited function name, it creates a new entry in its own `user_ns` — the parent's closure is unaffected.

---

## Open Decisions

1. **Should non-closure `def` values also inherit for `:self`?** Current plan: closures only. Rationale: data values (counters, intermediate results) are context-specific to the parent's computation. If the child needs data, it comes through the tool args (context). Functions are reusable behavior — that's what makes inheritance valuable.

2. **Prompt header wording**: `";; === user/ (inherited) ==="` vs `";; === inherited functions ==="`. The former is consistent with existing `user/` naming. The latter is more descriptive. Recommendation: use `";; === user/ (inherited) ==="` for consistency.

3. **`:fn` in JSON Schema**: Since PTC-Lisp agents don't use JSON Schema for tool calling (they use text-rendered signatures), this may not need implementation. Only relevant if text-mode agents need to call tools with `:fn` params. Defer until needed.

4. **Max inherited functions**: Should we cap the number of inherited functions to prevent prompt bloat? At depth 10 with 5 functions per level, that's 50 inherited functions. Recommendation: no cap initially, monitor in practice. The prompt cost of `(name [params]) ; "docstring"` is ~15 tokens per function — manageable.
