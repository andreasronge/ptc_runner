# PTC-Lisp Function Parameter Destructuring Specification

This document specifies the addition of full destructuring support in anonymous function (`fn`) parameters, bringing parity with `let` bindings.

**Related Documents:**
- [ptc-lisp-specification.md](ptc-lisp-specification.md) — Language specification
- [ptc-lisp-llm-guide.md](ptc-lisp-llm-guide.md) — LLM prompt reference
- [ptc-lisp-integration-spec.md](ptc-lisp-integration-spec.md) — Pipeline integration

---

## 1. Motivation

### 1.1 Problem Statement

Currently, PTC-Lisp rejects destructuring patterns in `fn` parameters:

```clojure
;; This fails with: "fn parameters must be simple symbols"
(fn [[k v]] {:key k :value v})
```

This forces awkward workarounds when iterating over grouped data:

```clojure
;; Current workaround - verbose and non-idiomatic
(->> ctx/expenses
     (group-by :category)
     (map (fn [entry]
            {:category (first entry)
             :average_amount (avg-by :amount (last entry))})))
```

### 1.2 Use Case: Map Iteration

The `map` function over a map passes each entry as a `[key value]` vector. Without vector destructuring, users must use `first`/`last`:

```clojure
;; Current (clunky)
(map (fn [entry] {:cat (first entry) :avg (avg-by :amount (last entry))}) grouped)

;; Desired (idiomatic)
(map (fn [[category expenses]] {:cat category :avg (avg-by :amount expenses)}) grouped)
```

### 1.3 Design Goals

1. **Parity with `let`**: `fn` parameters should support the same patterns as `let` bindings
2. **Vector destructuring**: Enable `[[a b]]` patterns for tuple-like data
3. **Map destructuring**: Enable `[{:keys [a b]}]` patterns for map data
4. **Composability**: Patterns can be nested (e.g., `[{:keys [name]} remaining]`)

---

## 2. Specification

### 2.1 Supported Patterns

#### Simple Variable (existing)
```clojure
(fn [x] body)        ;; x binds to the argument
```

#### Vector/Sequential Destructuring (new)
```clojure
(fn [[a b]] body)           ;; a=first, b=second of argument
(fn [[a b & rest]] body)    ;; NOT SUPPORTED (no rest patterns)
(fn [[_ value]] body)       ;; _ is a valid binding (discards)
```

#### Map Destructuring (new)
```clojure
(fn [{:keys [a b]}] body)           ;; extract :a and :b from map arg
(fn [{:keys [a] :or {a 0}}] body)   ;; with default value
(fn [{:keys [a] :as m}] body)       ;; bind extracted + whole map
```

#### Nested Patterns (new)
```clojure
(fn [[key {:keys [amount]}]] body)  ;; vector containing map
(fn [{:keys [user]} {:keys [id]}] body)  ;; multiple map params (note: multi-arity)
```

### 2.2 Pattern Grammar

```
pattern        ::= simple_var | vector_pattern | map_pattern
simple_var     ::= symbol
vector_pattern ::= '[' pattern* ']'
map_pattern    ::= '{' :keys '[' symbol* ']' [:or map] [:as symbol] '}'
```

### 2.3 Arity Rules

- Function arity is the count of top-level patterns
- A destructuring pattern counts as one parameter
- `(fn [[a b]] ...)` has arity 1 (expects one argument that destructures into two bindings)

### 2.4 Error Cases

| Scenario | Error |
|----------|-------|
| Arity mismatch | `{:arity_mismatch, expected, got}` |
| Vector pattern on non-list | `{:destructure_error, "expected list, got: ..."}` |
| Map pattern on non-map | `{:destructure_error, "expected map, got: ..."}` |
| Fewer elements than pattern | `{:destructure_error, "not enough elements"}` |

### 2.5 Extra Elements Handling

When the input has more elements than the pattern specifies:
- **Vector**: Extra elements are ignored (Clojure behavior)
- **Map**: Extra keys are ignored (only specified keys extracted)

---

## 3. Implementation Plan

### 3.1 Files to Modify

| File | Changes |
|------|---------|
| `lib/ptc_runner/lisp/core_ast.ex` | Add `{:destructure, {:seq, [pattern()]}}` to pattern type |
| `lib/ptc_runner/lisp/analyze.ex` | Extend `analyze_pattern` for vectors; update `analyze_fn_params` |
| `lib/ptc_runner/lisp/eval.ex` | Extend `match_pattern`; update `apply_fun` and `eval_closure_arg` |
| `docs/ptc-lisp-llm-guide.md` | Update syntax reference and remove warnings |

### 3.2 AST Changes

#### CoreAST Type Updates

```elixir
# Before
@type pattern ::
        {:var, atom()}
        | {:destructure, {:keys, [atom()], keyword()}}
        | {:destructure, {:as, atom(), pattern()}}

# After
@type pattern ::
        {:var, atom()}
        | {:destructure, {:keys, [atom()], keyword()}}
        | {:destructure, {:as, atom(), pattern()}}
        | {:destructure, {:seq, [pattern()]}}  # NEW

# Before
@type simple_param :: {:var, atom()}

# After (remove simple_param, use pattern)
# {:fn, [pattern()], t()}
```

### 3.3 Analyzer Changes

#### Update `analyze_pattern`

```elixir
# Add vector pattern support
defp analyze_pattern({:vector, elements}) do
  with {:ok, patterns} <- analyze_pattern_list(elements) do
    {:ok, {:destructure, {:seq, patterns}}}
  end
end

defp analyze_pattern_list(elements) do
  Enum.reduce_while(elements, {:ok, []}, fn elem, {:ok, acc} ->
    case analyze_pattern(elem) do
      {:ok, p} -> {:cont, {:ok, [p | acc]}}
      {:error, _} = err -> {:halt, err}
    end
  end)
  |> case do
    {:ok, rev} -> {:ok, Enum.reverse(rev)}
    other -> other
  end
end
```

#### Update `analyze_fn_params`

```elixir
# Change from analyze_simple_param to analyze_pattern
defp analyze_fn_params({:vector, param_asts}) do
  Enum.reduce_while(param_asts, {:ok, []}, fn ast, {:ok, acc} ->
    case analyze_pattern(ast) do  # Was: analyze_simple_param
      {:ok, pattern} -> {:cont, {:ok, [pattern | acc]}}
      {:error, _} = err -> {:halt, err}
    end
  end)
  |> case do
    {:ok, rev} -> {:ok, Enum.reverse(rev)}
    other -> other
  end
end
```

### 3.4 Evaluator Changes

#### Extend `match_pattern`

```elixir
# Add sequential pattern matching
defp match_pattern({:destructure, {:seq, patterns}}, value) when is_list(value) do
  if length(value) < length(patterns) do
    raise "destructure error: expected at least #{length(patterns)} elements, got #{length(value)}"
  end

  patterns
  |> Enum.zip(value)
  |> Enum.reduce(%{}, fn {pattern, val}, acc ->
    Map.merge(acc, match_pattern(pattern, val))
  end)
end

# Error case for wrong type
defp match_pattern({:destructure, {:seq, _}}, value) do
  raise "destructure error: expected list, got #{inspect(value)}"
end
```

#### Update `apply_fun` (Closure Application)

```elixir
# Before
defp apply_fun({:closure, param_names, body, closure_env}, args, ctx, memory, tool_exec) do
  if length(param_names) != length(args) do
    {:error, {:arity_mismatch, length(param_names), length(args)}}
  else
    bindings = Enum.zip(param_names, args) |> Map.new()
    new_env = Map.merge(closure_env, bindings)
    do_eval(body, ctx, memory, new_env, tool_exec)
  end
end

# After
defp apply_fun({:closure, patterns, body, closure_env}, args, ctx, memory, tool_exec) do
  if length(patterns) != length(args) do
    {:error, {:arity_mismatch, length(patterns), length(args)}}
  else
    bindings =
      Enum.zip(patterns, args)
      |> Enum.reduce(%{}, fn {pattern, arg}, acc ->
        Map.merge(acc, match_pattern(pattern, arg))
      end)
    new_env = Map.merge(closure_env, bindings)
    do_eval(body, ctx, memory, new_env, tool_exec)
  end
end
```

#### Update `eval_closure_arg` (HOF Compatibility)

This is **critical** - closures passed to `Enum.map`, `Enum.filter`, etc. go through this path:

```elixir
# Before
defp eval_closure_arg(arg, param_names, body, closure_env, ctx, memory, tool_exec) do
  if length(param_names) != 1 do
    raise ArgumentError, "arity mismatch: expected 1, got #{length(param_names)}"
  end

  bindings = Enum.zip(param_names, [arg]) |> Map.new()
  new_env = Map.merge(closure_env, bindings)
  # ...
end

# After
defp eval_closure_arg(arg, patterns, body, closure_env, ctx, memory, tool_exec) do
  if length(patterns) != 1 do
    raise ArgumentError, "arity mismatch: expected 1, got #{length(patterns)}"
  end

  [pattern] = patterns
  bindings = match_pattern(pattern, arg)
  new_env = Map.merge(closure_env, bindings)
  # ...
end
```

---

## 4. Test Plan

### 4.1 Unit Tests: Analyzer

```elixir
describe "fn with destructuring patterns" do
  test "analyzes vector pattern" do
    {:ok, ast} = analyze("(fn [[a b]] a)")
    assert {:fn, [{:destructure, {:seq, [{:var, :a}, {:var, :b}]}}], _body} = ast
  end

  test "analyzes map pattern" do
    {:ok, ast} = analyze("(fn [{:keys [x y]}] x)")
    assert {:fn, [{:destructure, {:keys, [:x, :y], []}}], _body} = ast
  end

  test "analyzes nested pattern" do
    {:ok, ast} = analyze("(fn [[k {:keys [v]}]] v)")
    # Vector containing symbol and map pattern
  end

  test "still supports simple params" do
    {:ok, ast} = analyze("(fn [x] x)")
    assert {:fn, [{:var, :x}], _} = ast
  end
end
```

### 4.2 Unit Tests: Evaluator

```elixir
describe "closure with destructuring" do
  test "vector destructuring in fn" do
    assert {:ok, 1, _, _} = run("((fn [[a b]] a) [1 2])")
    assert {:ok, 2, _, _} = run("((fn [[a b]] b) [1 2])")
  end

  test "map destructuring in fn" do
    assert {:ok, 10, _, _} = run("((fn [{:keys [x]}] x) {:x 10})")
  end

  test "ignores extra vector elements" do
    assert {:ok, 1, _, _} = run("((fn [[a]] a) [1 2 3])")
  end

  test "error on insufficient elements" do
    assert {:error, _} = run("((fn [[a b c]] a) [1 2])")
  end
end
```

### 4.3 E2E Tests

```elixir
describe "group-by with destructuring" do
  test "average by category using destructuring" do
    expenses = [
      %{category: "food", amount: 100},
      %{category: "food", amount: 50},
      %{category: "transport", amount: 30}
    ]

    program = """
    (->> ctx/expenses
         (group-by :category)
         (map (fn [[category items]]
                {:category category
                 :average (avg-by :amount items)}))
         (sort-by :category))
    """

    assert {:ok, result, _, _} = run(program, context: %{expenses: expenses})
    assert [
      %{category: "food", average: 75.0},
      %{category: "transport", average: 30.0}
    ] = result
  end
end
```

### 4.4 Property Tests

```elixir
property "vector destructuring extracts correct positions" do
  check all a <- term(), b <- term() do
    program = "((fn [[x y]] [y x]) [#{inspect(a)} #{inspect(b)}])"
    {:ok, [^b, ^a], _, _} = run(program)
  end
end
```

---

## 5. Documentation Updates

### 5.1 LLM Guide Changes

Update `docs/ptc-lisp-llm-guide.md`:

**Before (Special Forms section):**
```clojure
(fn [x] body)                      ; anonymous function (simple params only, no destructuring)
```

**After:**
```clojure
(fn [x] body)                      ; anonymous function with simple param
(fn [[a b]] body)                  ; vector destructuring
(fn [{:keys [a b]}] body)          ; map destructuring
```

**Remove from Common Mistakes table:**
```
| `(fn [{:keys [a b]}] ...)` | `(fn [m] (let [{:keys [a b]} m] ...))` |
```

**Add to Core Functions section (map clarification):**
```clojure
; map over a map: use destructuring for clean access
(map (fn [[k v]] {:key k :val v}) my-map)
```

### 5.2 Specification Updates

Update `docs/ptc-lisp-specification.md` to document the new capability.

---

## 6. Migration Notes

### 6.1 Backward Compatibility

This change is **fully backward compatible**:
- Simple symbol params continue to work unchanged
- Existing programs are unaffected
- No breaking changes to the public API

### 6.2 LLM Prompt Updates

After implementation, regenerate the LLM prompt via `PtcRunner.Lisp.Schema.to_prompt()` to include the new syntax.

---

## 7. Out of Scope

The following are explicitly NOT included in this implementation:

- **Rest patterns** (`[a b & rest]`) - Would require additional AST node type
- **Named map keys** (`{:keys [a] :strs [b]}`) - Only `:keys` is supported
- **Multi-arity functions** (`(fn ([x] ...) ([x y] ...))`) - Different feature
- **Argument validation at analysis time** - Patterns are validated at runtime

---

## 8. Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Runtime errors from wrong types | Clear error messages with type info |
| Performance impact on HOFs | `match_pattern` is simple recursion; negligible overhead |
| Breaking existing closures | Fully backward compatible; simple params still work |
| LLM generates invalid patterns | Update prompt; errors guide correction |

---

## 9. Success Criteria

1. All existing tests pass (no regressions)
2. New unit tests for pattern analysis and evaluation
3. E2E test demonstrating `group-by` with destructuring
4. LLM guide updated with new syntax
5. DeepSeek-style programs work without modification
