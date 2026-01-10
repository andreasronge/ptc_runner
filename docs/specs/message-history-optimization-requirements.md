# Message History Optimization - Requirements

Extracted from [message-history-optimization.md](./message-history-optimization.md)

## Prerequisites

| ID | Requirement | Notes |
|----|-------------|-------|
| PRE-001 | Issue #603 (Messages stored in Step) must be completed before implementation | Blocking dependency |

## API Configuration

| ID | Requirement | Notes |
|----|-------------|-------|
| API-001 | `compression: true` enables compression with default strategy | Uses `SingleUserCoalesced` |
| API-002 | `compression: {Strategy, opts}` enables with custom strategy and options | e.g., `{SingleUserCoalesced, println_limit: 10}` |
| API-003 | `compression: false` or `nil` disables compression (default) | |
| API-004 | Default `println_limit` is 15 | Most recent println calls shown |
| API-005 | Default `tool_call_limit` is 20 | Most recent tool calls shown |
| API-006 | `Compression.normalize/1` returns `{strategy, opts}` tuple | Handles `true`, `false`, `Module`, `{Module, opts}` |
| API-007 | Options inherited like other SubAgent options | |

## Architecture

| ID | Requirement | Notes |
|----|-------------|-------|
| ARC-001 | `Turn` struct captures immutable turn records | Fields: number, program, result, prints, tool_calls, memory, success? |
| ARC-002 | Turns list is append-only (no mutation) | Each turn is a snapshot of that cycle's execution |
| ARC-003 | `Compression` behaviour defines strategy interface | `to_messages/3` and `name/0` callbacks |
| ARC-004 | Compression is a pure render function | Same input always produces same output, no side effects |
| ARC-005 | `SingleUserCoalesced` is the default strategy | Accumulates all context into single USER message |
| ARC-006 | Turn count derived from `length(turns)`, not messages | Message array length varies by compression strategy |
| ARC-007 | `Step.turns` replaces `Step.trace` | Each Turn contains data previously in trace_entry plus prints |

## Namespace Design (REPL with Prelude)

| ID | Requirement | Notes |
|----|-------------|-------|
| NS-001 | `tool/` namespace for provided tools (side effects) | e.g., `(tool/fetch-users "admin")` |
| NS-002 | `data/` namespace for provided input data (read-only) | e.g., `data/products` |
| NS-003 | `user/` namespace for LLM definitions (prelude) | Grows each turn with def/defn |
| NS-004 | Auto-fallback: bare name resolves to `tool/` if no local definition exists | |
| NS-005 | Auto-fallback: bare name resolves to `data/` if no local definition exists | |
| NS-006 | Local definitions take precedence over fallback | |
| NS-007 | Ambiguous reference (both `tool/foo` and `data/foo` exist) raises runtime exception | Error: `{:error, {:ambiguous_reference, "..."}}` |
| NS-008 | Initial `input_data` keys shown in `data/` section | Unified format with user definitions |
| NS-009 | Explicit namespace access (`data/foo`) bypasses local shadowing | LLM can always access shadowed values via full namespace |
| NS-010 | Turn 1: `user/` section empty or omitted | REPL with no prelude loaded |
| NS-011 | Turn N+1: `user/` section shows accumulated definitions | Prelude grows each turn |
| NS-012 | `tool/` and `data/` sections are stable (cacheable) | Only `user/` changes between turns |

## Summary Format (Unified Namespaces)

### Namespace Section Headers

| ID | Requirement | Notes |
|----|-------------|-------|
| FMT-001 | Tool section header: `;; === tool/ ===` | |
| FMT-002 | Data section header: `;; === data/ ===` | |
| FMT-003 | User section header: `;; === user/ (your prelude) ===` | |

### Tool Namespace Format

| ID | Requirement | Notes |
|----|-------------|-------|
| FMT-004 | Tool entry: `(tool/{name} {params})      ; {signature}` | Uses existing tool schema |

### Data Namespace Format

| ID | Requirement | Notes |
|----|-------------|-------|
| FMT-005 | Data entry: `data/{name}                    ; {type}, sample: {sample}` | |

### User Prelude Format (Best Effort)

| ID | Requirement | Notes |
|----|-------------|-------|
| FMT-006 | Function with docstring + return: `({name} [{params}])           ; "{docstring}" -> {type}` | Return type if called |
| FMT-007 | Function with docstring: `({name} [{params}])           ; "{docstring}"` | |
| FMT-008 | Function minimal: `({name} [{params}])` | Uncalled, no docstring |
| FMT-009 | Value with sample: `{name}                         ; = {type}, sample: {sample}` | |
| FMT-010 | Value without sample: `{name}                         ; = {type}` | |

### Execution History Format

| ID | Requirement | Notes |
|----|-------------|-------|
| FMT-011 | Tool calls header: `;; Tool calls made:` | |
| FMT-012 | Tool call entry: `;   {name}({args})` | Always show parens |
| FMT-013 | No tool calls: `;; No tool calls made` | |
| FMT-014 | Output header: `;; Output:` | |
| FMT-015 | Output lines have no prefix (preserve original) | |

### Section Ordering

| ID | Requirement | Notes |
|----|-------------|-------|
| FMT-016 | Section order: tool/ → data/ → user/ → Tool calls → Output | Empty sections omitted |
| FMT-017 | Summaries consolidated across all successful turns | Single lists, not per-turn blocks |
| FMT-018 | Output section rendered as-is without sanitization | Risk accepted (low probability) |

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

## Message Array Transformation

| ID | Requirement | Notes |
|----|-------------|-------|
| MSG-001 | All previous successful turns accumulate into single USER message | |
| MSG-002 | Message array structure: `[SYSTEM, USER(mission + context + turns left), ASSISTANT(current)]` | |
| MSG-003 | Mission text appears first in USER message | |
| MSG-004 | Blank line separates mission from accumulated context | |
| MSG-005 | "Turns left: N" at the end, unless final turn | Final turn: `FINAL TURN - you must call (return result) or (fail reason) now.` |
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
| DBG-001 | Full programs preserved in `Step.turns` | Each Turn contains complete execution data |
| DBG-002 | Turn contains: number, program, result, prints, tool_calls, memory, success? | See ARC-001 |
| DBG-003 | Serialization stores turns (summaries derived on-demand) | |
| DBG-004 | LLM prompt uses compressed summaries via Compression strategy | |
| DBG-005 | Debug/inspection uses full turns list | |

---

## Resolved Ambiguities

| ID | Resolution |
|----|------------|
| AMB-001 | NS-007 updated with error type: `{:error, {:ambiguous_reference, "..."}}` |
| AMB-002 | TYP-011: Implementation detail, use simplest representation |
| AMB-003 | MSG-005: Show "Turns left: N" unless final turn (use existing warning message) |
| AMB-004 | DEF-007: Semicolons removed entirely from docstrings |
| AMB-005 | TC-006: Fields are name, args, result. Result shown if no println, truncated |
| AMB-006 | API-006: `Compression.normalize/1` returns `{strategy, opts}` tuple (replaces `%HistoryOpts{}`) |
| AMB-007 | FMT-002: Always show parens, even for no-arg calls |
| AMB-008 | TC-007, TRN-010: FIFO (drop oldest). ~~TC-008: Dropped from architecture~~ |
| AMB-009 | TRN-009: No special handling, multiline output = one println call |
| AMB-010 | Confirmed: NS-007 covers this (runtime exception for ambiguous reference) |

## Change Log

| ID | Change |
|----|--------|
| CHG-001 | `compress_history` renamed to `compression` |
| CHG-002 | `%HistoryOpts{}` replaced with `{strategy, opts}` tuple |
| CHG-003 | Added `Turn` struct for immutable turn records |
| CHG-004 | Added `Compression` behaviour for strategy pattern |
| CHG-005 | `Step.trace` renamed to `Step.turns` |
| CHG-006 | TC-008 (consecutive call compression) dropped |
| CHG-007 | MSG-005 final turn message simplified (no emoji) |
| CHG-008 | Unified namespace model: tool/, data/, user/ shown consistently |
| CHG-009 | REPL with Prelude mental model added |
| CHG-010 | Format changed from `; Defined:` to namespace sections |
| CHG-011 | Prompt caching optimization: stable tool/data sections |
| CHG-012 | User defn shows params (best effort for return type) |

