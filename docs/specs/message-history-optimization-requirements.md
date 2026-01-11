# Message History Optimization - Requirements

Extracted from [message-history-optimization.md](./message-history-optimization.md) and [message-history-optimization-architecture.md](./message-history-optimization-architecture.md).

**Implementation:** See [message-history-optimization-roadmap.md](./message-history-optimization-roadmap.md) for GitHub issues.

**Last verified:** 2026-01-11 (CHG-027 to CHG-029)

## Prerequisites

| ID | Requirement | Notes |
|----|-------------|-------|
| PRE-001 | Issue #603 (Messages stored in Step) must be completed before implementation | Blocking dependency |
| PRE-002 | PTC-Lisp: Auto-fallback resolution for bare names to `tool/` or `data/` | See NS-004 to NS-006 |
| PRE-003 | PTC-Lisp: Return type capture for user-defined functions when called | For user/ prelude display |

## Breaking Changes

| ID | Change | From | To | Notes |
|----|--------|------|-----|-------|
| BRK-001 | SubAgent field rename | `prompt` | `mission` | More semantic - describes the task |
| BRK-002 | Step field rename | `trace` | `turns` | Structured turn data replaces raw trace |
| BRK-003 | Module rename | `PtcRunner.Prompt` | `PtcRunner.Template` | It's a template struct, not "the prompt" |
| BRK-004 | Sigil rename | `~PROMPT` | `~T` | Matches Template naming |
| BRK-005 | Module rename | `SubAgent.Prompt` | `SubAgent.SystemPrompt` | Explicitly about system prompt |
| BRK-006 | Module rename | `SubAgent.Template` | `SubAgent.MissionExpander` | Clearer purpose |
| BRK-007 | Module rename | `Lisp.Prompts` | `Lisp.LanguageSpec` | It's the language reference |
| BRK-008 | Debug option removed | `debug: true` required | Always captured | `raw_response` always in Turn |
| BRK-009 | Debug API options | `messages:`, `system:` | `view:`, `raw:` | Simpler, orthogonal options |

## Demo Migration

Required changes to the demo application (`demo/`):

| ID | File | Change | Action |
|----|------|--------|--------|
| MIG-001 | `agent.ex` | `prompt:` → `mission:` | Update `SubAgent.new()` calls |
| MIG-002 | `agent.ex` | `step.trace` → `step.turns` | Update `extract_program_from_trace/1` to use `Turn.program` |
| MIG-003 | `prompts.ex` | `Lisp.Prompts` → `Lisp.LanguageSpec` | Update alias |
| MIG-004 | `agent.ex` | System prompt is now static | Move role prefix to `system_prompt: %{prefix: ...}` |
| MIG-005 | `cli_base.ex` | `preview_prompt` output changes | Data/tools now in USER message (expected behavior change) |
| MIG-006 | `*_cli.ex` | `print_trace` API changes | Update to new options (`raw:`, `view:`) |

## API Configuration

| ID | Requirement | Notes |
|----|-------------|-------|
| API-001 | `compression: true` enables compression with default strategy | Uses `SingleUserCoalesced` |
| API-002 | `compression: {Strategy, opts}` enables with custom strategy and options | e.g., `{SingleUserCoalesced, println_limit: 10}` |
| API-003 | `compression: false` or `nil` disables compression (default) | |
| API-004 | Default `println_limit` is 15 | Most recent println calls shown |
| API-005 | Default `tool_call_limit` is 20 | Most recent tool calls shown |
| API-006 | `Compression.normalize/1` returns `{strategy, opts}` tuple | Handles `nil`, `true`, `false`, `Module`, `{Module, opts}` |
| API-007 | Options inherited like other SubAgent options | |

## Architecture

| ID | Requirement | Notes |
|----|-------------|-------|
| ARC-001 | `Turn` struct captures immutable turn records | Fields: number, raw_response, program, result, prints, tool_calls, memory, success? |
| ARC-002 | Turns list is append-only (no mutation) | Each turn is a snapshot of that cycle's execution |
| ARC-003 | `Compression` behaviour defines strategy interface | `to_messages/3` and `name/0` callbacks |
| ARC-004 | Compression is a pure render function | Same input always produces same output, no side effects |
| ARC-005 | `SingleUserCoalesced` is the default strategy | Accumulates all context into single USER message |
| ARC-006 | Turn count derived from `length(turns)`, not messages | Message array length varies by compression strategy |
| ARC-007 | `Step.turns` replaces `Step.trace` | Each Turn contains data previously in trace_entry plus prints |
| ARC-008 | SYSTEM prompt is fully static (cacheable) | Language spec + output format only, no tools/data |
| ARC-009 | Tools and data rendered in USER message, not SYSTEM | Enables prompt caching; tool/data stable across turns |
| ARC-010 | `raw_response` captures full LLM output including reasoning | Always captured, no debug flag needed |
| ARC-011 | Static SYSTEM prompt applies regardless of `compression` setting | Prompt structure is universal |
| ARC-012 | `compression` option only affects turn history rendering | Not prompt structure |

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
| FMT-004 | Tool entry: `tool/{name}({params}) -> {return_type}` | PTC-Lisp signature syntax (see signature-syntax.md) |

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
| DEF-009 | Order: functions first, then values (grouped by type) | More predictable for LLMs |

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
| MSG-006 | SYSTEM prompt static text unchanged (language spec + output format) | Tools/data rendering moves to USER (see ARC-009) |
| MSG-007 | Mission is NEVER removed | Critical requirement |

## Compression Rules

| ID | Requirement | Notes |
|----|-------------|-------|
| CMP-001 | Successful turn results compressed to summary | Definitions, tool calls, output accumulated |
| CMP-002 | Failed turns use conditional collapsing based on recovery | See ERR-001 to ERR-005 |
| CMP-003 | Compression happens at start of each new turn (not storage time) | Pure render function |

## Error Handling (Conditional Collapsing)

| ID | Requirement | Notes |
|----|-------------|-------|
| ERR-001 | Failed turns use conditional collapsing based on recovery status | Not always shown |
| ERR-002 | If last turn failed: show most recent error only (limit: 1) | Helps LLM recover |
| ERR-003 | If last turn succeeded: collapse ALL previous errors | Clean message after recovery |
| ERR-004 | Error format: code block + error message in USER message | See format below |
| ERR-005 | Successful turn data still accumulated even after failed turns | Definitions, tool calls preserved |

### Error Display Format (when shown)

```
---
Your previous attempt:
```clojure
{failed_program}
```

Error: {error_message}
---
```

## Single-Shot Mode

| ID | Requirement | Notes |
|----|-------------|-------|
| SS-001 | No compression for `max_turns: 1` | |
| SS-002 | `max_turns` defaults to 5 if not specified | |

## Debug and Tracing

| ID | Requirement | Notes |
|----|-------------|-------|
| DBG-001 | Full programs preserved in `Step.turns` | Each Turn contains complete execution data |
| DBG-002 | Turn contains: number, raw_response, program, result, prints, tool_calls, memory, success? | See ARC-001 |
| DBG-003 | Serialization stores turns (summaries derived on-demand) | |
| DBG-004 | LLM prompt uses compressed summaries via Compression strategy | |
| DBG-005 | Debug/inspection uses full turns list | |
| DBG-006 | System prompt is static, NOT stored per-turn | Use `SubAgent.SystemPrompt.generate/2` to view |

### Debug API

| ID | Requirement | Notes |
|----|-------------|-------|
| DBG-007 | `SubAgent.Debug.print_trace(step)` shows programs + results | Default view |
| DBG-008 | `SubAgent.Debug.print_trace(step, raw: true)` includes raw_response | LLM reasoning |
| DBG-009 | `SubAgent.Debug.print_trace(step, view: :compressed)` shows what LLM sees | Compressed format |
| DBG-010 | `SubAgent.Debug.print_trace(step, usage: true)` adds token statistics | |

| Option | Values | Description |
|--------|--------|-------------|
| `view` | `:turns` (default), `:compressed` | Perspective to render |
| `raw` | `boolean` | Include `raw_response` in turns view |
| `usage` | `boolean` | Add token statistics |

---

## Implementation Phases

Implementation follows a "build alongside, swap atomically" strategy. Each phase keeps tests green. Cleanup requirements (CLN-*) must be completed before a phase is considered done.

| Phase | Description | Cleanup Required |
|-------|-------------|------------------|
| 1 | New modules (Turn, Compression, Namespace) | None (additive) |
| 2 | Dual-write: Add `turns` alongside `trace` | CLN-001 |
| 3 | Module renames (atomic, one per commit) | CLN-002 to CLN-006 |
| 4 | Dual-field: Add `mission` alongside `prompt` | CLN-007 |
| 5 | Wire compression (flag-gated, opt-in) | CLN-008 |
| 6 | Make compression default, update demo | None |

## Cleanup Requirements

Cleanup requirements ensure old code is deleted, not left to rot. Each CLN-* blocks its phase from completion.

### Enforcement

Add `lib/ptc_runner/migration_guard.ex` with compile-time guards. Uncomment each guard when its phase begins—compilation fails until the old code is deleted. See [migration-guard.md](./migration-guard.md) for implementation hints.

### Phase 2 Cleanup (Dual-write complete)

| ID | Delete | Condition | Blocked By |
|----|--------|-----------|------------|
| CLN-001 | `Step.trace` field | All consumers use `Step.turns` | Phase 2 tests pass |

### Phase 3 Cleanup (Module renames)

| ID | Delete | Renamed To | Blocked By |
|----|--------|------------|------------|
| CLN-002 | `PtcRunner.Prompt` module | `PtcRunner.Template` | CLN-001 |
| CLN-003 | `~PROMPT` sigil | `~T` sigil | CLN-002 |
| CLN-004 | `PtcRunner.SubAgent.Prompt` module | `SubAgent.SystemPrompt` | CLN-001 |
| CLN-005 | `PtcRunner.SubAgent.Template` module | `SubAgent.MissionExpander` | CLN-001 |
| CLN-006 | `PtcRunner.Lisp.Prompts` module | `Lisp.LanguageSpec` | CLN-001 |

### Phase 4 Cleanup (API field rename)

| ID | Delete | Condition | Blocked By |
|----|--------|-----------|------------|
| CLN-007 | `SubAgent.prompt` field | All consumers use `mission` | CLN-002 to CLN-006 |

### Phase 5 Cleanup (Debug API)

| ID | Delete | Condition | Blocked By |
|----|--------|-----------|------------|
| CLN-008 | `debug: true` option handling | `raw_response` always captured in Turn | CLN-007 |
| CLN-009 | `messages:` debug option | Replaced by `view:` option | CLN-008 |
| CLN-010 | `system:` debug option | Replaced by `raw:` option | CLN-008 |

### Phase 6 Cleanup (Dual-write removal)

| ID | Delete | Condition | Blocked By |
|----|--------|-----------|------------|
| CLN-011 | `opts[:prompt]` fallback in `SubAgent.new/1` | All callers use `mission:` | CLN-007 |
| CLN-012 | Dual-write code in Loop (if any remains) | Only `turns` populated | CLN-001 |

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
| AMB-011 | ERR-001 to ERR-003 corrected: failed turns use conditional collapsing, not "never compressed" |
| AMB-012 | SYSTEM prompt contains only language spec + output format (no tools/data) |

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
| CHG-013 | Added Breaking Changes section (BRK-001 to BRK-007) |
| CHG-014 | Added PTC-Lisp prerequisites (PRE-002, PRE-003) |
| CHG-015 | Fixed ARC-001: added `raw_response` field to Turn struct |
| CHG-016 | Added ARC-008 to ARC-010: SYSTEM static, tools/data in USER |
| CHG-017 | Fixed ERR-001 to ERR-003: conditional collapsing (was incorrectly "never compressed") |
| CHG-018 | Added ERR-004, ERR-005: error format and recovery behavior |
| CHG-019 | Removed CMP-002, CMP-003 (obsolete), simplified to CMP-001 to CMP-003 |
| CHG-020 | Added Debug API requirements (DBG-006 to DBG-010) |
| CHG-021 | `SubAgent.prompt` renamed to `SubAgent.mission` (BRK-001) |
| CHG-022 | Added BRK-008: debug option no longer required (raw_response always captured) |
| CHG-023 | Added BRK-009: Debug API options simplified (messages:/system: → view:/raw:) |
| CHG-024 | Added Demo Migration section (MIG-001 to MIG-006) |
| CHG-025 | Added Implementation Phases section with incremental strategy |
| CHG-026 | Added Cleanup Requirements (CLN-001 to CLN-012) to ensure old code deletion |
| CHG-027 | DEF-009: Changed from "order of definition" to "functions first, then values" |
| CHG-028 | MSG-006: Clarified "unchanged" means static text only (tools/data move to USER) |
| CHG-029 | FMT-004: Updated format to match implementation, added signature-syntax.md reference |
| CHG-030 | Added implementation roadmap with 24 GitHub issues |
| CHG-031 | Added ARC-011, ARC-012: Clarify compression scope vs prompt structure |
| CHG-032 | Roadmap: Issue #18 now "prepare only" (no behavior change) |
| CHG-033 | Roadmap: Issue #21 now dual-write only (no trace deletion) |
| CHG-034 | Roadmap: Issue #22 is atomic switch (static SYSTEM + namespaces in USER) |
| CHG-035 | Roadmap: Added Issue #24 (Phase 9) for final cleanup |
| CHG-036 | Roadmap: Issue #2 now requires edge case tests for regression risk |
| CHG-037 | Roadmap: Issue #17 now requires get/1 API verification |

