# Message History Optimization - Requirements

Extracted from [message-history-optimization.md](./message-history-optimization.md)

## Prerequisites

| ID | Requirement | Notes |
|----|-------------|-------|
| PRE-001 | Issue #603 (Messages stored in Step) must be completed before implementation | Blocking dependency |

## API Configuration

| ID | Requirement | Notes |
|----|-------------|-------|
| API-001 | `compress_history: true` enables compression with defaults | |
| API-002 | `compress_history: [println_limit: N, tool_call_limit: M]` enables with custom limits | |
| API-003 | `compress_history: false` disables compression (default) | |
| API-004 | Default `println_limit` is 15 | Most recent println calls shown |
| API-005 | Default `tool_call_limit` is 20 | Most recent tool calls shown |
| API-006 | Options normalized to `%HistoryOpts{}` struct internally | |
| API-007 | Options inherited like other SubAgent options | |

## Namespace Design

| ID | Requirement | Notes |
|----|-------------|-------|
| NS-001 | `tool/` namespace for provided tools (side effects) | e.g., `(tool/fetch-users "admin")` |
| NS-002 | `data/` namespace for provided input data (read-only) | e.g., `data/products` |
| NS-003 | Bare names for user definitions | e.g., `(my-helper x)` |
| NS-004 | Auto-fallback: bare name resolves to `tool/` if no local definition exists | |
| NS-005 | Auto-fallback: bare name resolves to `data/` if no local definition exists | |
| NS-006 | Local definitions take precedence over fallback | |
| NS-007 | Ambiguous reference (both `tool/foo` and `data/foo` exist) raises runtime exception | Error: `{:error, {:ambiguous_reference, "Symbol 'X' exists in both tool/ and data/ namespaces. Use explicit namespace."}}` |
| NS-008 | Initial `input_data` keys available as `data/key` | Not shown in Defined section (system prompt describes available data) |
| NS-009 | Explicit namespace access (`data/foo`) bypasses local shadowing | LLM can always access shadowed values via full namespace |

## Summary Format

| ID | Requirement | Notes |
|----|-------------|-------|
| FMT-001 | Tool calls header: `; Tool calls:` | |
| FMT-002 | Tool call entry: `;   {name}({args})` | Two-space indent after semicolon. Always show parens, even for no-arg calls: `get-inventory()` |
| FMT-003 | No tool calls: `; No tool calls made` | |
| FMT-004 | Function with docstring: `; Function: {name} - "{docstring}"` | |
| FMT-005 | Function without docstring: `; Function: {name}` | |
| FMT-006 | Defined with docstring + sample: `; Defined: {name} - "{docstring}" = {type}, sample: {sample}` | |
| FMT-007 | Defined with sample (no docstring): `; Defined: {name} = {type}, sample: {sample}` | |
| FMT-008 | Defined without sample: `; Defined: {name} = {type}` | |
| FMT-009 | Output header: `; Output:` | |
| FMT-010 | Output lines have no prefix (preserve original) | |
| FMT-011 | Section order: Tool calls → Functions → Defined → Output | |
| FMT-012 | Empty sections are omitted entirely | |
| FMT-013 | Summaries consolidated across all successful turns | Single Tool calls list, single Defined list (not per-turn blocks) |
| FMT-014 | Output section rendered as-is without sanitization | Risk of confusing patterns accepted (low probability in practice) |

## Type Vocabulary

| ID | Requirement | Notes |
|----|-------------|-------|
| TYP-001 | Empty list `[]` → `list[0]` | |
| TYP-002 | Non-empty list `[1,2,3]` → `list[N]` where N is length | |
| TYP-003 | Empty map `%{}` → `map[0]` | |
| TYP-004 | Non-empty map `%{a: 1}` → `map[N]` where N is key count | |
| TYP-005 | String → `string` | |
| TYP-006 | Integer → `integer` | |
| TYP-007 | Float → `float` | |
| TYP-008 | Boolean → `boolean` | |
| TYP-009 | Keyword → `keyword` | |
| TYP-010 | Nil → `nil` | |
| TYP-011 | Closure → `#fn[...]` | Implementation detail - use simplest representation |
| TYP-012 | MapSet → `set[N]` where N is size | e.g., `set[3]` |

## Truncation

| ID | Requirement | Notes |
|----|-------------|-------|
| TRN-001 | Use `Format.to_clojure/2` for all value truncation | |
| TRN-002 | Samples: `limit: 3, printable_limit: 80` | |
| TRN-003 | Tool call args: `limit: 3, printable_limit: 60` | |
| TRN-004 | Truncated collections show `... (N items, showing first M)` | |
| TRN-005 | Truncated strings show `...` suffix | |
| TRN-006 | println limit applies to number of calls, not lines | |
| TRN-007 | Output lines preserved as-is (not truncated individually) | |
| TRN-008 | Interpreter captures each `(println ...)` call in Step | |
| TRN-009 | Multiline println output treated as one println call | No special handling |
| TRN-010 | When `println_limit` reached, drop oldest (FIFO) | |
| TRN-011 | println output truncated per call (e.g., 2000 chars) | "Preserved as-is" means no prefixing, not unlimited length |

## Samples vs Output Logic

| ID | Requirement | Notes |
|----|-------------|-------|
| SAM-001 | If turn has NO println: show samples in Defined lines | |
| SAM-002 | If turn has println: omit samples, show Output section | |
| SAM-003 | Samples use Clojure-style syntax (`{:key value}`) | |

## Definitions

| ID | Requirement | Notes |
|----|-------------|-------|
| DEF-001 | Redefinition within same turn: only final value in summary | |
| DEF-002 | Redefinition across turns: latest wins | |
| DEF-003 | `(def x nil)` → `; Defined: x = nil` | |
| DEF-004 | `(def x [])` → `; Defined: x = list[0]` | |
| DEF-005 | Both `defn` and `def` support docstrings | |
| DEF-006 | Docstrings captured at execution time | |
| DEF-007 | Docstrings with semicolons are sanitized (`;` characters removed entirely) | |
| DEF-008 | Accumulated definitions shown from all previous turns | |
| DEF-009 | Order of appearance follows order of definition | |

## Tool Calls

| ID | Requirement | Notes |
|----|-------------|-------|
| TC-001 | Tool calls accumulated across all turns | |
| TC-002 | Tool calls limited by `tool_call_limit` | |
| TC-003 | Tool call format: `name(args)` with truncated args | |
| TC-004 | Tool results NOT shown in tool call list | |
| TC-005 | Tool results appear in Defined section if stored via `def` | |
| TC-006 | Data comes from `Step.tool_calls` (fields: name, args, result) | Result shown if no println used, truncated like samples |
| TC-007 | When `tool_call_limit` reached, drop oldest (FIFO) | |
| TC-008 | Consecutive identical calls compressed: `foo("bar") x5` | Only if calls are consecutive, not mixed with other calls |

## Message Array Transformation

| ID | Requirement | Notes |
|----|-------------|-------|
| MSG-001 | All previous successful turns accumulate into single USER message | |
| MSG-002 | Message array structure: `[SYSTEM, USER(mission + context + turns left), ASSISTANT(current)]` | |
| MSG-003 | Mission text appears first in USER message | |
| MSG-004 | Blank line separates mission from accumulated context | |
| MSG-005 | "Turns left: N" at the end, unless final turn | Final turn: `⚠️ FINAL TURN - you must call (return result) or (fail response) next.` |
| MSG-006 | SYSTEM prompt unchanged | |
| MSG-007 | Mission is NEVER removed | Critical requirement |

## Compression Rules

| ID | Requirement | Notes |
|----|-------------|-------|
| CMP-001 | Successful turn results compressed to summary | |
| CMP-002 | Failed turn code kept in full | |
| CMP-003 | Failed turns keep full assistant/user message pairs | |
| CMP-004 | Compression happens at start of each new turn (not storage time) | |

## Error Handling

| ID | Requirement | Notes |
|----|-------------|-------|
| ERR-001 | Failed turns NOT compressed | |
| ERR-002 | Multiple failed turns each keep full assistant/user pairs | |
| ERR-003 | Error message appears in USER message after failed ASSISTANT | |

## Single-Shot Mode

| ID | Requirement | Notes |
|----|-------------|-------|
| SS-001 | No compression for `max_turns: 1` | |
| SS-002 | `max_turns` defaults to 5 if not specified | |

## Debug and Tracing

| ID | Requirement | Notes |
|----|-------------|-------|
| DBG-001 | Full programs preserved in `Step.trace` | |
| DBG-002 | Trace contains: turn, program, output, definitions | |
| DBG-003 | Serialization stores both summaries and full programs | |
| DBG-004 | LLM prompt uses compressed summaries | |
| DBG-005 | Debug/inspection uses full trace | |

---

## Resolved Ambiguities

| ID | Resolution |
|----|------------|
| AMB-001 | NS-007 updated with error type: `{:error, {:ambiguous_reference, "..."}}` |
| AMB-002 | TYP-011: Implementation detail, use simplest representation |
| AMB-003 | MSG-005: Show "Turns left: N" unless final turn (use existing warning message) |
| AMB-004 | DEF-007: Semicolons removed entirely from docstrings |
| AMB-005 | TC-006: Fields are name, args, result. Result shown if no println, truncated |
| AMB-006 | API-006: `%HistoryOpts{}` defined during implementation (fields: println_limit, tool_call_limit) |
| AMB-007 | FMT-002: Always show parens, even for no-arg calls |
| AMB-008 | TC-007, TRN-010: FIFO (drop oldest). TC-008: Consecutive identical calls compressed |
| AMB-009 | TRN-009: No special handling, multiline output = one println call |
| AMB-010 | Confirmed: NS-007 covers this (runtime exception for ambiguous reference) |

## Additional Requirements (from review)

| ID | Requirement | Notes |
|----|-------------|-------|
| NS-008 | Initial `input_data` keys available as `data/key` | Not shown in Defined section |
| NS-009 | Explicit namespace access bypasses local shadowing | `data/foo` always accessible |
| FMT-013 | Summaries consolidated across all successful turns | Single lists, not per-turn blocks |
| FMT-014 | Output section rendered as-is | Risk of confusing patterns accepted |
| TYP-012 | MapSet → `set[N]` | |
| TRN-011 | println output truncated per call | e.g., 2000 chars per call |

