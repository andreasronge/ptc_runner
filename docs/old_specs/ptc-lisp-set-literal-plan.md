# PTC-Lisp Set Literal Implementation Plan

**Version:** 1.0
**Status:** Proposed
**Author:** Claude Code
**Date:** 2025-12-09

---

## 1. Overview

This document specifies the implementation of Clojure `#{...}` set literal syntax for PTC-Lisp. Sets are currently explicitly not supported (documented in `ptc-lisp-specification.md` line 212), and LLMs commonly use this syntax causing parse errors.

### 1.1 Goals

1. Parse `#{1 2 3}` syntax as set literals
2. Represent sets efficiently at runtime using Elixir MapSet
3. Provide basic set operations for data transformation
4. Maintain LLM-friendliness with silent duplicate handling

### 1.2 Non-Goals

- Full Clojure set API (union, intersection, difference)
- Set comprehensions or advanced constructs
- Lazy set operations

---

## 2. Design Decisions

### 2.1 Runtime Representation: MapSet

**Decision:** Use Elixir's `MapSet` for set representation.

**Rationale:**
- O(1) membership testing via `MapSet.member?/2`
- Built-in deduplication on construction
- Consistent with Clojure semantics (hash-based sets)
- Clear semantic distinction from vectors (lists)
- Future-proof for efficient set operations if needed later

**Alternative considered:** List-based sets
- Pros: Simpler, reuses existing vector evaluation
- Cons: O(n) membership, loses semantic distinction
- **Rejected** - MapSet is clearly superior

### 2.2 Parser Strategy: Compound Token

**Decision:** Parse `#{` as a single compound token.

**Rationale:**
- Avoids look-ahead complexity for `#` disambiguation
- Matches existing NimbleParsec pattern using `string()`
- Future extensibility for other `#` syntaxes (`#()`, `#"..."`)
- Better error messages ("expected `}` to close set literal")

**Implementation:** The set combinator must come BEFORE the map combinator in the choice list to correctly match `#{` before `{`.

### 2.3 Duplicate Handling: Silent Deduplication

**Decision:** `#{1 1 2}` silently evaluates to a set with elements `1` and `2`.

**Rationale:**
- Matches Clojure behavior
- LLM-friendly (prevents errors on accidental duplicates)
- Consistent with "safe by default" design philosophy

**Alternative considered:** Error on duplicates
- Pros: Strict validation, catches potential mistakes
- Cons: More friction, breaks on benign duplicates
- **Rejected** - Silent dedup is more practical

### 2.4 Scope: Minimal Operations

**Decision:** Implement only essential operations for v1.

**Included:**
| Function | Description |
|----------|-------------|
| `#{...}` | Set literal syntax |
| `set?` | Type predicate |
| `set` | Constructor from collection |
| `contains?` | Membership test |
| `count` | Element count |
| `empty?` | Empty check |

**Deferred:**
- `union`, `intersection`, `difference`
- `subset?`, `superset?`
- `disj` (remove element), `conj` (add element)

**Rationale:** Keep the language minimal. LLMs can use `distinct` on vectors or explicit filtering as workarounds.

### 2.5 Collection Semantics

**Decision:** `coll?` returns `false` for sets.

**Rationale:**
- Maintains current semantics where `coll?` only returns true for vectors
- Sets have their own `set?` predicate
- Prevents unintended behavior in `flatten` and other coll?-based operations

---

## 3. Specification

### 3.1 Syntax

```ebnf
set = "#{" expression* "}"
```

Examples:
```clojure
#{}                    ; empty set
#{1 2 3}               ; set with 3 elements
#{:a :b :c}            ; keyword set
#{1 "a" :b}            ; mixed types
#{[1 2] [3 4]}         ; set of vectors
#{#{1 2}}              ; nested set
```

### 3.2 Evaluation Semantics

1. All elements are evaluated left-to-right
2. Evaluated values are collected into a MapSet
3. Duplicates are silently removed during MapSet construction
4. Order is not preserved (sets are unordered)

```clojure
#{(+ 1 2) 3}           ; evaluates to #{3} (deduped after evaluation)
#{nil true false}      ; valid set with 3 elements
```

### 3.3 Type Predicates

```clojure
(set? #{1 2})          ; => true
(set? [1 2])           ; => false
(set? {})              ; => false (map, not set)

(coll? #{1 2})         ; => false (sets are not "collections")
(vector? #{1 2})       ; => false
(map? #{1 2})          ; => false
```

### 3.4 Operations

#### `set?` - Type Predicate
```clojure
(set? x)               ; returns true if x is a set
```

#### `set` - Constructor
```clojure
(set [1 2 2 3])        ; => #{1 2 3}
(set #{1 2})           ; => #{1 2} (identity for sets)
```

#### `contains?` - Membership Test
```clojure
(contains? #{1 2 3} 2) ; => true
(contains? #{1 2 3} 5) ; => false
(contains? #{nil} nil) ; => true
```

#### `count` - Element Count
```clojure
(count #{1 2 3})       ; => 3
(count #{})            ; => 0
```

#### `empty?` - Empty Check
```clojure
(empty? #{})           ; => true
(empty? #{1})          ; => false
```

### 3.5 Equality

Sets are compared by value, unordered:
```clojure
(= #{1 2} #{2 1})      ; => true
(= #{1 2} #{1 2 3})    ; => false
(= #{1 2} [1 2])       ; => false (different types)
```

### 3.6 Collection Operations on Sets

Sets implement Enumerable, so collection operations work but return **vectors** (not sets):

| Operation | Behavior |
|-----------|----------|
| `map` | Returns vector: `(map inc #{1 2})` → `[2 3]` |
| `filter` | Returns vector: `(filter odd? #{1 2 3})` → `[1 3]` |
| `remove` | Returns vector: `(remove odd? #{1 2 3})` → `[2]` |
| `reduce` | Works normally (iteration order undefined) |

**Unsupported operations** (sets are unordered):

| Operation | Reason |
|-----------|--------|
| `first` | Sets have no defined order |
| `last` | Sets have no defined order |
| `nth` | Sets have no defined order |
| `sort` | Sets are inherently unordered |
| `sort-by` | Sets are inherently unordered |

---

## 4. AST Representation

### 4.1 Raw AST (Parser Output)

```elixir
{:set, [element1, element2, ...]}
```

Examples:
```elixir
# #{}
{:set, []}

# #{1 2 3}
{:set, [1, 2, 3]}

# #{:a "b"}
{:set, [{:keyword, :a}, {:string, "b"}]}
```

### 4.2 CoreAST (After Analysis)

Same structure, with analyzed elements:
```elixir
{:set, [analyzed_element1, analyzed_element2, ...]}
```

### 4.3 Runtime Value

Elixir `MapSet.t()`:
```elixir
MapSet.new([1, 2, 3])
```

---

## 5. Implementation Plan

### 5.1 Phase 1: Parser

**Files:**
- `lib/ptc_runner/lisp/parser.ex`
- `lib/ptc_runner/lisp/parser_helpers.ex`

**Changes in `parser.ex`:**

Add set combinator after line ~131 (after map_literal definition):

```elixir
defcombinatorp(
  :set,
  ignore(string("#{"))
  |> concat(parsec(:ws))
  |> repeat(parsec(:expr) |> concat(parsec(:ws)))
  |> ignore(string("}"))
  |> tag(:set)
  |> map({ParserHelpers, :build_set, []})
)
```

Update `:expr` combinator choice list (around line 147). **Critical:** `parsec(:set)` must come BEFORE `parsec(:map_literal)`:

```elixir
defcombinatorp(
  :expr,
  choice([
    nil_literal,
    true_literal,
    false_literal,
    float_literal,
    integer_literal,
    string_literal,
    keyword,
    symbol,
    parsec(:vector),
    parsec(:set),         # <-- NEW: must come before map_literal
    parsec(:map_literal),
    parsec(:list)
  ])
)
```

**Changes in `parser_helpers.ex`:**

Add builder function:

```elixir
def build_set({:set, elements}) do
  {:set, elements}
end
```

### 5.2 Phase 2: AST Types

**Files:**
- `lib/ptc_runner/lisp/ast.ex`
- `lib/ptc_runner/lisp/core_ast.ex`

**Changes in `ast.ex`:**

Add to type spec (around line 12):

```elixir
@type t ::
        nil
        | boolean()
        | number()
        | {:string, String.t()}
        | {:keyword, atom()}
        # Collections
        | {:vector, [t()]}
        | {:set, [t()]}        # <-- NEW
        | {:map, [{t(), t()}]}
        # Symbols
        | {:symbol, atom()}
        | {:ns_symbol, :ctx | :memory, atom()}
        | {:list, [t()]}
```

**Changes in `core_ast.ex`:**

Add to type spec (around line 27):

```elixir
@type t ::
        literal
        # Collections
        | {:vector, [t()]}
        | {:set, [t()]}        # <-- NEW
        | {:map, [{t(), t()}]}
        # ... rest of types
```

### 5.3 Phase 3: Analyzer

**File:** `lib/ptc_runner/lisp/analyze.ex`

Add clause for set analysis (after map clause, around line 56):

```elixir
defp do_analyze({:set, elems}) do
  with {:ok, elems2} <- analyze_list(elems) do
    {:ok, {:set, elems2}}
  end
end
```

### 5.4 Phase 4: Evaluator

**File:** `lib/ptc_runner/lisp/eval.ex`

**Update value type spec** (around line 20):

```elixir
@type value ::
        nil
        | boolean()
        | number()
        | String.t()
        | atom()
        | list()
        | map()
        | MapSet.t()           # <-- NEW
        | function()
        | {:closure, [CoreAST.pattern()], CoreAST.t(), env()}
```

**Add evaluation clause** (after map evaluation, around line 84):

```elixir
# Sets: evaluate all elements, then create MapSet
defp do_eval({:set, elems}, ctx, memory, env, tool_exec) do
  result =
    Enum.reduce_while(elems, {:ok, [], memory}, fn elem, {:ok, acc, mem} ->
      case do_eval(elem, ctx, mem, env, tool_exec) do
        {:ok, v, mem2} -> {:cont, {:ok, [v | acc], mem2}}
        {:error, _} = err -> {:halt, err}
      end
    end)

  case result do
    {:ok, values, memory2} -> {:ok, MapSet.new(values), memory2}
    {:error, _} = err -> err
  end
end
```

### 5.5 Phase 5: Runtime Functions

**File:** `lib/ptc_runner/lisp/runtime.ex`

#### Critical: MapSet is a struct, so `is_map(set)` returns `true`

Multiple existing functions use `when is_map(coll)` guards that would incorrectly match MapSet and crash (expecting `{k, v}` tuples). We must add explicit `%MapSet{}` clauses BEFORE generic `is_map` clauses.

**Add set predicate:**

```elixir
@doc "Returns true if x is a set"
def set?(x), do: is_struct(x, MapSet)
```

**Add set constructor:**

```elixir
@doc "Convert collection to set"
def set(coll) when is_list(coll), do: MapSet.new(coll)
def set(%MapSet{} = set), do: set
```

**Update `map`** (add clause BEFORE `is_map` clause - returns vector like Clojure):

```elixir
def map(f, %MapSet{} = set), do: Enum.map(set, f)
def map(f, coll) when is_map(coll) do
  # existing implementation
end
```

**Update `mapv`** (add clause BEFORE `is_map` clause):

```elixir
def mapv(f, %MapSet{} = set), do: Enum.map(set, f)
def mapv(f, coll) when is_map(coll), do: # existing
```

**Update `filter`** (add clause for sets - returns vector):

```elixir
def filter(pred, %MapSet{} = set), do: Enum.filter(set, pred)
def filter(pred, coll) when is_list(coll), do: Enum.filter(coll, pred)
```

**Update `remove`** (add clause for sets - returns vector):

```elixir
def remove(pred, %MapSet{} = set), do: Enum.reject(set, pred)
def remove(pred, coll) when is_list(coll), do: Enum.reject(coll, pred)
```

**Update `contains?`** (add clause BEFORE `is_map` clause):

```elixir
def contains?(%MapSet{} = set, val), do: MapSet.member?(set, val)
def contains?(coll, key) when is_map(coll), do: Map.has_key?(coll, key)
def contains?(coll, val) when is_list(coll), do: val in coll
```

**Update `count` and `empty?`** (add explicit MapSet handling):

```elixir
def count(%MapSet{} = set), do: MapSet.size(set)
# ... existing count clauses

def empty?(%MapSet{} = set), do: MapSet.size(set) == 0
# ... existing empty? clauses
```

### 5.6 Phase 6: Environment Bindings

**File:** `lib/ptc_runner/lisp/env.ex`

Add to type predicates section (around line 122):

```elixir
{:set?, {:normal, &Runtime.set?/1}},
{:set, {:normal, &Runtime.set/1}},
```

### 5.7 Phase 7: Formatter

**File:** `lib/ptc_runner/lisp/formatter.ex`

Add formatting clause (after map formatting, around line 33):

```elixir
def format({:set, elems}) do
  "\#{#{format_list(elems)}}"
end
```

**Note:** The `#` character needs to be properly escaped in the string. Using `"\#{"` or `~s(#{)` works in Elixir.

### 5.8 Phase 8: Documentation

**File:** `docs/ptc-lisp-specification.md`

1. **Remove** "Not supported: Sets (`#{}`)" from line 212

2. **Add Section 3.8** after Section 3.7 (Maps):

```markdown
### 3.8 Sets

Unordered collections of unique values:

```clojure
#{}                    ; empty set
#{1 2 3}               ; set with 3 elements
#{1 1 2}               ; duplicates silently removed: equivalent to #{1 2}
#{:a :b :c}            ; keyword set
```

Sets are **unordered** - iteration order is not guaranteed.

**Set operations:**

| Function | Signature | Description |
|----------|-----------|-------------|
| `set?` | `(set? x)` | Returns true if x is a set |
| `set` | `(set coll)` | Convert collection to set |
| `count` | `(count #{1 2})` | Returns element count |
| `empty?` | `(empty? #{})` | Returns true if empty |
| `contains?` | `(contains? #{1 2} 1)` | Membership test (O(1)) |

**Not supported for sets:** `first`, `last`, `nth`, `map`, `filter`, `sort` (sets are unordered).
```

3. **Update Section 8.6** (Type Predicates) to add:

```markdown
| `set?` | Is set? |
```

4. **Update Section 14** (Grammar) to add set production:

```ebnf
set = "#{" expression* "}" ;
```

And add `set` to the `expression` alternatives.

**File:** `docs/ptc-lisp-llm-guide.md`

1. Add sets to Data Types section:

```markdown
#{1 2 3}               ; sets (unordered, unique values)
```

2. Add set functions to reference:

```markdown
; Sets
(set? x)               ; is x a set?
(set [1 2 2])          ; convert to set: #{1 2}
(contains? #{1 2} 1)   ; membership: true
(count #{1 2 3})       ; count: 3
(empty? #{})           ; empty check: true
```

---

## 6. Testing Strategy

### 6.1 Parser Tests

**File:** `test/ptc_runner/lisp/parser_test.exs`

```elixir
describe "sets" do
  test "empty set" do
    assert {:ok, {:set, []}} = Parser.parse("#{}")
  end

  test "set with elements" do
    assert {:ok, {:set, [1, 2, 3]}} = Parser.parse("#{1 2 3}")
  end

  test "set with mixed types" do
    assert {:ok, {:set, [{:keyword, :a}, {:string, "b"}, 3]}} =
           Parser.parse("#{:a \"b\" 3}")
  end

  test "nested set" do
    assert {:ok, {:set, [{:set, [1, 2]}]}} = Parser.parse("#{#{1 2}}")
  end

  test "set containing vector" do
    assert {:ok, {:set, [{:vector, [1, 2]}]}} = Parser.parse("#{[1 2]}")
  end

  test "set with whitespace and commas" do
    assert {:ok, {:set, [1, 2, 3]}} = Parser.parse("#{ 1 , 2 , 3 }")
  end

  test "unclosed set returns error" do
    assert {:error, {:parse_error, _}} = Parser.parse("#{1 2 3")
  end

  test "space between # and { is invalid" do
    assert {:error, {:parse_error, _}} = Parser.parse("# {1 2}")
  end
end
```

### 6.2 Analyzer Tests

**File:** `test/ptc_runner/lisp/analyze_test.exs`

```elixir
describe "set analysis" do
  test "analyzes set elements" do
    {:ok, ast} = Parser.parse("#{1 x}")
    {:ok, analyzed} = Analyze.analyze(ast)
    assert {:set, [1, {:var, :x}]} = analyzed
  end

  test "analyzes nested set" do
    {:ok, ast} = Parser.parse("#{#{1}}")
    {:ok, analyzed} = Analyze.analyze(ast)
    assert {:set, [{:set, [1]}]} = analyzed
  end
end
```

### 6.3 Evaluator Tests

**File:** `test/ptc_runner/lisp/eval_test.exs`

```elixir
describe "set evaluation" do
  test "empty set" do
    {:ok, result, _} = run("#{}")
    assert result == MapSet.new([])
  end

  test "set with literals" do
    {:ok, result, _} = run("#{1 2 3}")
    assert MapSet.equal?(result, MapSet.new([1, 2, 3]))
  end

  test "set deduplicates elements" do
    {:ok, result, _} = run("#{1 1 2 2 3}")
    assert MapSet.equal?(result, MapSet.new([1, 2, 3]))
    assert MapSet.size(result) == 3
  end

  test "set with evaluated expressions" do
    {:ok, result, _} = run("#{(+ 1 2) 3}")
    # Both (+ 1 2) and 3 evaluate to 3, so deduped
    assert MapSet.equal?(result, MapSet.new([3]))
  end
end

describe "set predicates" do
  test "set? returns true for sets" do
    {:ok, result, _} = run("(set? #{1 2})")
    assert result == true
  end

  test "set? returns false for vectors" do
    {:ok, result, _} = run("(set? [1 2])")
    assert result == false
  end

  test "set? returns false for maps" do
    {:ok, result, _} = run("(set? {:a 1})")
    assert result == false
  end
end

describe "set operations" do
  test "contains? on set checks membership" do
    {:ok, result, _} = run("(contains? #{1 2 3} 2)")
    assert result == true
  end

  test "contains? on set returns false for non-member" do
    {:ok, result, _} = run("(contains? #{1 2 3} 5)")
    assert result == false
  end

  test "count on set" do
    {:ok, result, _} = run("(count #{1 2 3})")
    assert result == 3
  end

  test "empty? on empty set" do
    {:ok, result, _} = run("(empty? #{})")
    assert result == true
  end

  test "empty? on non-empty set" do
    {:ok, result, _} = run("(empty? #{1})")
    assert result == false
  end

  test "set constructor from vector" do
    {:ok, result, _} = run("(set [1 2 2 3])")
    assert MapSet.equal?(result, MapSet.new([1, 2, 3]))
  end

  test "set constructor preserves set" do
    {:ok, result, _} = run("(set #{1 2})")
    assert MapSet.equal?(result, MapSet.new([1, 2]))
  end
end

describe "set equality" do
  test "sets with same elements are equal" do
    {:ok, result, _} = run("(= #{1 2} #{2 1})")
    assert result == true
  end

  test "sets with different elements are not equal" do
    {:ok, result, _} = run("(= #{1 2} #{1 2 3})")
    assert result == false
  end
end

describe "collection operations on sets" do
  test "map on set returns vector" do
    {:ok, result, _} = run("(map inc #{1 2 3})")
    # Result is a list (vector), order may vary
    assert is_list(result)
    assert Enum.sort(result) == [2, 3, 4]
  end

  test "filter on set returns vector" do
    {:ok, result, _} = run("(filter odd? #{1 2 3 4})")
    assert is_list(result)
    assert Enum.sort(result) == [1, 3]
  end

  test "remove on set returns vector" do
    {:ok, result, _} = run("(remove odd? #{1 2 3 4})")
    assert is_list(result)
    assert Enum.sort(result) == [2, 4]
  end

  test "reduce on set works" do
    {:ok, result, _} = run("(reduce + 0 #{1 2 3})")
    assert result == 6
  end
end
```

### 6.4 Formatter Tests

**File:** `test/ptc_runner/lisp/formatter_test.exs`

```elixir
describe "set formatting" do
  test "empty set" do
    assert Formatter.format({:set, []}) == "#{}"
  end

  test "set with elements" do
    assert Formatter.format({:set, [1, 2, 3]}) == "#{1 2 3}"
  end

  test "nested set" do
    assert Formatter.format({:set, [{:set, [1]}]}) == "#{#{1}}"
  end

  test "set roundtrip" do
    original = "#{1 2 3}"
    {:ok, ast} = Parser.parse(original)
    formatted = Formatter.format(ast)
    {:ok, reparsed} = Parser.parse(formatted)
    assert ast == reparsed
  end
end
```

### 6.5 End-to-End Tests

**File:** `test/ptc_runner/lisp/ptc_lisp_e2e_test.exs` or similar

```elixir
describe "set literals end-to-end" do
  test "parse and evaluate set literal" do
    assert {:ok, result, _, _} = PtcRunner.Lisp.run("#{1 2 3}")
    assert MapSet.equal?(result, MapSet.new([1, 2, 3]))
  end

  test "set in pipeline" do
    code = """
    (let [ids #{1 2 3}]
      (contains? ids 2))
    """
    assert {:ok, true, _, _} = PtcRunner.Lisp.run(code)
  end

  test "set membership with where predicate" do
    code = """
    (let [valid-ids #{1 2 3}]
      (->> [{:id 1} {:id 4} {:id 2}]
           (filter (fn [x] (contains? valid-ids (:id x))))))
    """
    {:ok, result, _, _} = PtcRunner.Lisp.run(code)
    assert result == [%{id: 1}, %{id: 2}]
  end
end
```

---

## 7. Edge Cases

### 7.1 Parser Edge Cases

| Case | Expected Result |
|------|-----------------|
| `#{}` | Empty set `{:set, []}` |
| `#{1 2 3}` | Set with 3 elements |
| `#{1, 2, 3}` | Same (comma is whitespace) |
| `#{1 1 2}` | Set parsed as `{:set, [1, 1, 2]}` (dedup at eval) |
| `#{#{1}}` | Nested set |
| `#{[1] [1]}` | Set with two identical vectors (dedupe at eval) |
| `#{` (unclosed) | Parse error |
| `# {1}` (space) | Parse error |

### 7.2 Evaluation Edge Cases

| Case | Expected Result |
|------|-----------------|
| `#{(+ 1 2) 3}` | `#{3}` (dedupe after evaluation) |
| `#{nil}` | Valid set containing nil |
| `#{true false nil}` | Valid set with 3 elements |
| `#{1 1 1}` | `#{1}` (deduped) |
| `#{[1 2] [1 2]}` | Set with 1 element (vectors equal by value) |
| `#{{:a 1} {:a 1}}` | Set with 1 element (maps equal by value) |

### 7.3 Runtime Edge Cases

| Operation | Result |
|-----------|--------|
| `(set? #{})` | `true` |
| `(set? [])` | `false` |
| `(set? {})` | `false` (map, not set) |
| `(coll? #{})` | `false` |
| `(contains? #{} 1)` | `false` |
| `(count #{})` | `0` |
| `(empty? #{})` | `true` |
| `(= #{} #{})` | `true` |

---

## 8. Complexity Analysis

### 8.1 High Complexity Areas

1. **Parser Combinator Ordering**
   - The `parsec(:set)` combinator MUST come before `parsec(:map_literal)` in the choice list
   - Both use `{` as a closing delimiter, but `#{` is a longer match
   - Failure here causes `#{...}` to parse as `#` (invalid) followed by `{...}` (map)

2. **Formatter String Escaping**
   - The `#` character in the format output must be properly escaped
   - Elixir string interpolation uses `#{}` syntax
   - Use `~s(\#{)` or escape as `"\#{"` to avoid interpolation

3. **MapSet is a Struct (Critical Regression Risk)**
   - `is_map(%MapSet{})` returns `true` in Elixir
   - ALL functions with `when is_map(coll)` guards will incorrectly match MapSet
   - Must add explicit `%MapSet{}` clauses BEFORE generic `is_map` clauses
   - Affected functions: `map`, `mapv`, `contains?`, `get`, `get_in`, `flex_get`
   - Failure causes runtime crashes (expects `{k, v}` tuples, gets single values)

4. **contains? Overloading**
   - Three distinct behaviors for maps (keys), lists (values), and sets (membership)
   - MapSet clause MUST come first due to `is_map` issue above
   - Pattern matching on `%MapSet{}` is cleaner than `is_struct(x, MapSet)`

### 8.2 Low Complexity Areas

1. **AST Type Changes** - Simple addition to type specs
2. **Analyzer** - Follows existing pattern for collections
3. **Evaluator** - Nearly identical to vector evaluation, just wrap in MapSet
4. **Documentation** - Straightforward additions

---

## 9. Future Enhancements

The following operations are intentionally deferred but could be added later:

### 9.1 Set Operations

```clojure
(union #{1 2} #{2 3})       ; => #{1 2 3}
(intersection #{1 2} #{2 3}); => #{2}
(difference #{1 2} #{2 3})  ; => #{1}
```

### 9.2 Set Predicates

```clojure
(subset? #{1} #{1 2})       ; => true
(superset? #{1 2} #{1})     ; => true
```

### 9.3 Set Modification

```clojure
(conj #{1 2} 3)             ; => #{1 2 3}
(disj #{1 2 3} 2)           ; => #{1 3}
```

### 9.4 Collection Interop

```clojure
(into #{} [1 2 3])          ; => #{1 2 3}
(into [] #{1 2 3})          ; => [1 2 3] (order undefined)
```

---

## 10. Summary

This plan adds Clojure-style `#{...}` set literal syntax to PTC-Lisp with:

- **MapSet runtime representation** for O(1) operations
- **Silent deduplication** for LLM-friendliness
- **Minimal operation set**: `set?`, `set`, `contains?`, `count`, `empty?`
- **8 implementation phases** across 10+ files
- **Comprehensive testing** at parser, analyzer, evaluator, and E2E levels

The implementation maintains PTC-Lisp's design philosophy of simplicity and safety while eliminating a common source of LLM-generated parse errors.
