# PTC-Lisp v2: Requirements Specification

**Source Document:** `docs/ptc-lisp-v2-namespace-specs.md`
**Generated:** 2025-01-04

---

## 1. Namespace Model Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-NS-1 | Two-namespace design: `ctx` (system, read-only) and user (LLM, read-write via `def`/`defn`) | §2.1 |
| REQ-NS-2 | `ctx` namespace is read-only — LLM cannot modify `ctx/` bindings | §2.2 |
| REQ-NS-3 | `ctx` namespace is immutable within session — same values across all turns | §2.2 |
| REQ-NS-4 | User namespace is implicit — no `(ns user)` declaration needed | §2.3 |
| REQ-NS-5 | User-defined symbols require no prefix — access directly by name | §2.3 |
| REQ-NS-6 | User namespace bindings persist across turns | §2.3 |
| REQ-NS-7 | `ctx/` prefix always accesses context namespace and cannot be shadowed | §7.3 |

---

## 2. `def` Form Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-DEF-1 | Support syntax: `(def name value)` | §3.1 |
| REQ-DEF-2 | Support syntax with docstring: `(def name docstring value)` — docstring is ignored but allowed | §3.1 |
| REQ-DEF-3 | `def` returns the var (`#'name`), not the value | §3.1, §7.5 |
| REQ-DEF-4 | `def` creates or overwrites the binding | §3.1, §7.2 |
| REQ-DEF-5 | Value is evaluated before binding | §3.1 |
| REQ-DEF-6 | Binding persists until session ends or redefined | §3.1 |
| REQ-DEF-7 | No metadata support (`^:dynamic`, `^:private`, etc.) | §3.1 |
| REQ-DEF-8 | No destructuring in `def` | §3.1 |
| REQ-DEF-9 | `def` cannot shadow builtins — must return error | §7.3, §8.4 |
| REQ-DEF-10 | `def` can shadow `ctx` names, but `ctx/` prefix still works | §7.3 |
| REQ-DEF-11 | `def` bindings are NOT truncated — store full data | §2.4 |

---

## 3. `defn` Form Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-DEFN-1 | Support syntax: `(defn name [params] body)` | §3.2 |
| REQ-DEFN-2 | Support syntax with docstring: `(defn name docstring [params] body)` — docstring is ignored | §3.2 |
| REQ-DEFN-3 | `defn` is sugar for `(def name (fn [params] body))` | §3.2 |
| REQ-DEFN-4 | Functions persist across turns | §3.2 |
| REQ-DEFN-5 | Functions can reference other user-defined symbols | §3.2 |
| REQ-DEFN-6 | Functions can access `ctx/` data and call `ctx/` tools | §3.2 |
| REQ-DEFN-7 | No multi-arity support | §3.2 |
| REQ-DEFN-8 | No pre/post conditions | §3.2 |
| REQ-DEFN-9 | No destructuring in param list | §3.2 |
| REQ-DEFN-10 | No variadic args (`& rest`) | §3.2 |
| REQ-DEFN-11 | No closure capture in v1 — functions cannot close over `let`-bound variables | §3.2 |

---

## 4. Tool Invocation Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-TOOL-1 | Tools invoked via `(ctx/tool-name args)` syntax | §2.2 |
| REQ-TOOL-2 | Remove `(call "tool-name" args)` syntax | §4.1, §9.1 |
| REQ-TOOL-3 | `(ctx/name args)` checks tools first, then data | §11 (Resolved) |
| REQ-TOOL-4 | Tool name conflicts with data should be validated at SubAgent creation | §11 (Resolved) |

---

## 5. REPL History Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-REPL-1 | `*1`, `*2`, `*3` provide access to recent turn results | §2.4 |
| REQ-REPL-2 | REPL history is read-only and automatic | §2.4 |
| REQ-REPL-3 | REPL history truncated to ~1KB per entry (configurable) | §2.4 |
| REQ-REPL-4 | Returns `nil` if turn doesn't exist | §2.4 |
| REQ-REPL-5 | `*1`/`*2`/`*3` update automatically at turn boundaries | §7.4 |

---

## 6. Scope and Resolution Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-SCOPE-1 | Let-bound symbols shadow everything within lexical scope (including user-defined and builtins) | §7.3 |
| REQ-SCOPE-2 | Symbol resolution order: let-bindings → user namespace → builtins | §7.3, §8.4 |
| REQ-SCOPE-3 | User symbols resolved at runtime (not static analysis) | §8.4, §12.3 |

---

## 7. Evaluation Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-EVAL-1 | Each turn is a single expression; use `do` for multiple sub-expressions | §7.1 |
| REQ-EVAL-2 | Evaluation restarts fresh each turn (no continuation) | §7.4 |
| REQ-EVAL-3 | `return` and `fail` forms remain unchanged as special forms | §4.3 |
| REQ-EVAL-4 | Single-shot (`max_turns: 1`): last expression is result, no `return` needed | §8.6 |
| REQ-EVAL-5 | Multi-turn: must call `(return ...)` to terminate | §8.6 |
| REQ-EVAL-6 | Remove implicit map merge logic (memory contract) | §8.6, §9.3 |
| REQ-EVAL-7 | Remove `:return` key special handling | §8.6, §9.3 |
| REQ-EVAL-8 | Last expression = turn feedback (standard REPL behavior) | §8.6 |

---

## 8. Var Representation Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-VAR-1 | Vars print as `#'name` (e.g., `#'x`, `#'suspicious?`) | §7.5 |
| REQ-VAR-2 | No full namespace path needed (`#'x` not `#'user/x`) | §7.5 |
| REQ-VAR-3 | New AST node: `{:var, atom()}` for var references | §12.4 |
| REQ-VAR-4 | Support var reader syntax `#'x` to explicitly reference a var | RD-2 |

---

## 9. Prompt Template Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-PROMPT-1 | Present `ctx` namespace using Clojure comments format, not markdown | §5, §5.2 |
| REQ-PROMPT-2 | Signatures displayed as-is — no parsing or reformatting | §5.1 |
| REQ-PROMPT-3 | Prepend `ctx/` to tool names in prompt | §5.1 |
| REQ-PROMPT-4 | Descriptions on next line, indented with `;;   ` | §5.1 |
| REQ-PROMPT-5 | Include "Expected Output" section showing return type | §5.5 |
| REQ-PROMPT-6 | Include Quick Reference after namespace declaration | §5.6 |
| REQ-PROMPT-7 | Signature input params become `ctx/name` data entries | §5.5 |

---

## 10. SubAgent API Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-API-1 | Add `:description` field to SubAgent (optional, for external docs) | §5.7 |
| REQ-API-2 | `as_tool/1` requires `:description` to be set | §5.7 |
| REQ-API-3 | Add `:field_descriptions` field to SubAgent | §5.3 |
| REQ-API-4 | Add `:format_options` field to SubAgent | §8.8 |
| REQ-API-5 | Add `:field_descriptions` field to Step struct | §5.3 |
| REQ-API-6 | Add `:field_descriptions` field to CompiledAgent | §5.3 |

---

## 11. Description Flow Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-DESC-1 | `field_descriptions` must be preserved in CompiledAgent | §5.3 |
| REQ-DESC-2 | Output descriptions from agent A become input descriptions for agent B in chains | §5.3 |
| REQ-DESC-3 | `then!/2` must propagate field descriptions | §5.3 |
| REQ-DESC-4 | Tool descriptions appear in `ctx/` namespace when SubAgent used as tool | §5.7 |

---

## 12. Format Options Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-FMT-1 | `feedback_limit`: max collection items shown to LLM (default: 20) | §8.8 |
| REQ-FMT-2 | `feedback_max_chars`: max chars for feedback (default: 2KB) | §8.8 |
| REQ-FMT-3 | `history_max_bytes`: truncation limit for `*1`/`*2`/`*3` (default: 1KB) | §8.8 |
| REQ-FMT-4 | `result_limit`: inspect `:limit` for collections (default: 50) | §8.8 |
| REQ-FMT-5 | `result_max_chars`: final string truncation (default: 500) | §8.8 |
| REQ-FMT-6 | Turn feedback (shown to LLM) should be truncated: 20 items, 2KB default | §2.4 |
| REQ-FMT-7 | Large collections show count indicator (e.g., "500 items, showing first 20") | §8.8, §9.4 |
| REQ-FMT-8 | Move formatting logic from demo app to library (`ResponseHandler.format_result/2`) | §8.8 |

---

## 13. Turn Feedback Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-FB-1 | Feedback mimics Clojure REPL output — just the expression result | §9.4 |
| REQ-FB-2 | `def` feedback shows the var (`#'results`) | §9.4 |
| REQ-FB-3 | Remove "Memory Hints" from feedback | §9.4 |

---

## 14. Code Removal Requirements

### 14.1 Parser Removals

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-REM-P1 | Remove `memory/` namespace parsing from `ast.ex` | §9.1 |

### 14.2 Analyzer Removals

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-REM-A1 | Remove `{:ns_symbol, :memory, key}` dispatch | §9.1 |
| REQ-REM-A2 | Remove `memory/put` special form | §9.1 |
| REQ-REM-A3 | Remove `memory/get` special form | §9.1 |
| REQ-REM-A4 | Remove `(call "name" args)` special form | §9.1 |

### 14.3 Evaluator Removals

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-REM-E1 | Remove `{:memory, key}` eval clause | §9.1 |
| REQ-REM-E2 | Remove `{:memory_put, key, value}` eval clause | §9.1 |
| REQ-REM-E3 | Remove `{:memory_get, key}` eval clause | §9.1 |

### 14.4 Core AST Removals

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-REM-T1 | Remove `{:memory, atom()}` type | §9.1 |
| REQ-REM-T2 | Remove `{:memory_put, atom(), t()}` type | §9.1 |
| REQ-REM-T3 | Remove `{:memory_get, atom()}` type | §9.1 |

### 14.5 Memory Contract Removals

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-REM-M1 | Remove implicit map merge in `apply_memory_contract/3` | §9.1 |
| REQ-REM-M2 | Remove `:return` key special handling | §9.1 |
| REQ-REM-M3 | Remove `memory_delta` tracking | §9.1 |

### 14.6 Prompt Removals

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-REM-PR1 | Rewrite `lisp-addon-memory.md` for `def`/`defn` model | §9.1 |
| REQ-REM-PR2 | Remove memory accumulation docs | §9.1 |
| REQ-REM-PR3 | Replace `(call "tool" args)` examples with `(ctx/tool args)` | §9.1 |

---

## 15. New AST Node Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-AST-1 | Add `{:def, atom(), t()}` AST node | §8.3, §12 |
| REQ-AST-2 | Add `{:defn, atom(), list(), t()}` AST node (desugars to def + fn) | §8.3 |
| REQ-AST-3 | Add `{:ctx_call, atom(), [t()]}` AST node for tool invocation | §8.5, §12 |
| REQ-AST-4 | Add `{:var, atom()}` AST node for var references | §12.4 |

---

## 16. Struct Changes Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-STRUCT-1 | Rename `memory` to `user_ns` (or `user_namespace`) in EvalContext | §8.2 |
| REQ-STRUCT-2 | Add `:field_descriptions` to Step struct | §5.3 |
| REQ-STRUCT-3 | Add `:description` to SubAgent struct | §5.7 |
| REQ-STRUCT-4 | Add `:format_options` to SubAgent struct | §8.8 |
| REQ-STRUCT-5 | Add `:field_descriptions` to SubAgent struct | §5.3 |

---

## 17. Validation Requirements

| ID | Requirement | Section |
|----|-------------|---------|
| REQ-VAL-1 | Validate `def` cannot shadow builtins at evaluation time | §7.3, §8.4 |
| REQ-VAL-2 | Validate ctx/ tool vs data name conflict at SubAgent creation | §11 (Resolved) |
| REQ-VAL-3 | Validate chain key mismatch at `then!/2` — ensure output keys ⊇ input keys | §11 (Resolved) |
| REQ-VAL-4 | `def` inside `let` must produce clear error message for LLM | RD-4 |
| REQ-VAL-5 | Multiple expressions per turn must produce clear error message for LLM | RD-5 |

---

## Resolved Decisions

| ID | Question | Decision |
|----|----------|----------|
| RD-1 | Docstrings in `def`/`defn` | Allowed and ignored (see REQ-DEF-2, REQ-DEFN-2) |
| RD-2 | Var reader syntax `#'x` | Supported — see REQ-VAR-4 |
| RD-3 | Metadata support | Skip for v1 (see REQ-DEF-7) |
| RD-4 | `def` inside `let` | Error with clear message for LLM — see REQ-VAL-4 |
| RD-5 | Multiple expressions per turn | Only single expressions allowed; error with clear message — see REQ-VAL-5 |

---

## Implementation Groups (from §12.2)

These groups identify changes that must happen together atomically:

| Group | Description | Requirements |
|-------|-------------|--------------|
| Group 1 | Analyzer Changes | REQ-REM-A1 to A4, REQ-AST-1 to 3, REQ-VAL-1, REQ-VAL-4, REQ-VAL-5 |
| Group 2 | Evaluator Changes | REQ-REM-E1 to E3, REQ-DEF-* (eval), REQ-SCOPE-3 |
| Group 3 | Core Types | REQ-REM-T1 to T3, REQ-AST-1 to 4, REQ-VAR-4 |
| Group 4 | Parser Changes | REQ-REM-P1, REQ-VAR-4 |
| Group 5 | Memory Contract | REQ-REM-M1 to M3, REQ-EVAL-6 to 8 |
| Group 6 | Struct Additions | REQ-STRUCT-1 to 5, REQ-API-1 to 6 |
| Group 7 | Prompt Templates | REQ-REM-PR1 to PR3, REQ-PROMPT-1 to 7 |

---

## Summary

| Category | Count |
|----------|-------|
| Namespace Model | 7 |
| def Form | 11 |
| defn Form | 11 |
| Tool Invocation | 4 |
| REPL History | 5 |
| Scope and Resolution | 3 |
| Evaluation | 8 |
| Var Representation | 4 |
| Prompt Template | 7 |
| SubAgent API | 6 |
| Description Flow | 4 |
| Format Options | 8 |
| Turn Feedback | 3 |
| Code Removal | 17 |
| New AST Nodes | 4 |
| Struct Changes | 5 |
| Validation | 5 |
| **Total** | **112** |
