# Message History Optimization - Implementation Roadmap

Input for creating GitHub issues. Each issue section contains requirements to implement, dependencies, and acceptance criteria.

**Source:** [message-history-optimization-requirements.md](./message-history-optimization-requirements.md)

---

## Epic Overview

| Phase | Issues | Description |
|-------|--------|-------------|
| 0 | #1 | Foundation (PRE-001) |
| 1 | #2-#4 | PTC-Lisp enhancements |
| 2 | #5-#6 | Core types (Turn, TypeVocabulary) |
| 3 | #7-#10 | Namespace rendering |
| 4 | #11-#13 | Compression system |
| 5 | #14-#18 | Module renames + prepare static SYSTEM |
| 6 | #19-#20 | API changes & Debug API |
| 7 | #21-#22 | Integration & wiring (atomic switch) |
| 8 | #23 | Demo migration |
| 9 | #24 | Final cleanup |

---

## Phase 0: Foundation

### Issue #1: Messages stored in Step (PRE-001) ✅ COMPLETE

**Existing issue:** #603 (closed 2026-01-09)

This was the blocking dependency. Now complete - subsequent issues can proceed.

**Requirements:** PRE-001

**Status:** ✅ Complete

**Blocks:** All subsequent issues (now unblocked)

---

## Phase 1: PTC-Lisp Enhancements

### ~~Issue #2: Namespace auto-fallback resolution~~ ⏸️ DEFERRED

> **Decision:** Deferred from this epic. Implicit resolution adds complexity with high regression risk for modest benefit. Explicit namespaces (`tool/search`, `data/products`) are unambiguous and not painful in practice. See [#609](https://github.com/andreasronge/ptc_runner/issues/609).

<details>
<summary>Original spec (preserved for future reference)</summary>

Implement bare name resolution to `tool/` or `data/` namespaces when no local definition exists.

**Requirements:**
- NS-004: Auto-fallback to `tool/` if no local definition
- NS-005: Auto-fallback to `data/` if no local definition
- NS-006: Local definitions take precedence
- NS-007: Ambiguous reference raises `{:error, {:ambiguous_reference, "..."}}`
- NS-009: Explicit `data/foo` bypasses local shadowing
- PRE-002 (partial)

**Files to modify:**
- `lib/ptc_runner/lisp/analyze.ex`
- `lib/ptc_runner/lisp/env.ex`
- `lib/ptc_runner/lisp/eval.ex`

**Acceptance criteria:**
- `(search ...)` resolves to `(tool/search ...)` when `search` is a tool
- `products` resolves to `data/products` when in input_data
- Local `(def search ...)` shadows tool fallback
- Error when both `tool/foo` and `data/foo` exist and bare `foo` used

**Required edge case tests (high regression risk):**
- Local var shadows tool name → tool not called
- Local var set to nil → fallback does NOT trigger (nil is a valid value)
- Variable shadowing then redefinition → latest wins
- Explicit namespace `(tool/search ...)` works even when local `search` exists
- Explicit namespace `data/foo` bypasses local shadowing
- Ambiguous reference error message includes both namespaces

</details>

---

### Issue #3: Return type capture for user functions

Capture return types when user-defined functions are called, for display in `user/` prelude.

**Requirements:**
- PRE-003
- FMT-006 (partial): Return type shown when function called

**Files to modify:**
- `lib/ptc_runner/lisp/eval.ex` (closure call handling)
- Closure metadata structure

**Acceptance criteria:**
- After `(defn double [x] (* x 2))` and `(double 5)`, closure metadata contains `:return_type`
- Return type derived from actual call result
- Multiple calls: last return type wins

**Blocked by:** #1

**Blocks:** #9

---

### Issue #4: Capture println calls in Step

Interpreter captures each `(println ...)` call for later rendering in Output section.

**Requirements:**
- TRN-008: Interpreter captures each println call in Step
- TRN-009: Multiline output = one println call
- TRN-011: Per-call truncation (e.g., 2000 chars)

**Files to modify:**
- `lib/ptc_runner/lisp/eval.ex` (println special form)
- `lib/ptc_runner/step.ex` (add prints field if not present)

**Acceptance criteria:**
- `Step.prints` contains list of strings from println calls
- Order preserved
- Each println call = one entry (even if multiline)
- Long output truncated per call

**Blocked by:** #1

**Blocks:** #10, #12

---

## Phase 2: Core Types

### Issue #5: Turn struct

Create immutable Turn struct to capture each LLM interaction cycle.

**Requirements:**
- ARC-001: Turn struct with fields (number, raw_response, program, result, prints, tool_calls, memory, success?)
- ARC-002: Turns list is append-only
- ARC-010: raw_response always captured (no debug flag)
- DBG-001: Full programs preserved in Step.turns
- DBG-002: Turn contains complete execution data

**Files to create:**
- `lib/ptc_runner/turn.ex`

**Files to modify:**
- None yet (no integration)

**Acceptance criteria:**
- `Turn.success/6` and `Turn.failure/6` constructors work
- All fields accessible
- Struct is immutable (no update functions)

**Blocked by:** #1

**Blocks:** #12, #21

---

### Issue #6: TypeVocabulary module

Type labels for namespace rendering (list[N], map[N], string, etc.).

**Requirements:**
- TYP-001 to TYP-012: All type vocabulary rules

**Files to create:**
- `lib/ptc_runner/sub_agent/namespace/type_vocabulary.ex`

**Acceptance criteria:**
- `type_of([])` → `"list[0]"`
- `type_of([1,2,3])` → `"list[3]"`
- `type_of(%{a: 1})` → `"map[1]"`
- `type_of(MapSet.new([1,2]))` → `"set[2]"`
- `type_of({:closure, ...})` → `"#fn[...]"`

**Blocked by:** #1

**Blocks:** #8, #9

---

## Phase 3: Namespace Rendering

### Issue #7: Namespace.Tool module

Render `tool/` namespace section for USER message.

**Requirements:**
- NS-001: `tool/` namespace for provided tools
- NS-012: `tool/` section is stable (cacheable)
- FMT-001: Header `;; === tool/ ===`
- FMT-004: Entry format `tool/{name}({params}) -> {return_type}`

**Files to create:**
- `lib/ptc_runner/sub_agent/namespace/tool.ex`

**Dependencies:**
- Signature syntax from existing tool schema

**Acceptance criteria:**
- Empty tools map → `nil`
- Tools rendered with correct header and format
- Output matches FMT-004 format

**Blocked by:** #2

**Blocks:** #11

---

### Issue #8: Namespace.Data module

Render `data/` namespace section for USER message.

**Requirements:**
- NS-002: `data/` namespace for input data
- NS-008: Initial input_data keys shown in data/ section
- NS-012: `data/` section is stable (cacheable)
- FMT-002: Header `;; === data/ ===`
- FMT-005: Entry format with type and sample

**Files to create:**
- `lib/ptc_runner/sub_agent/namespace/data.ex`

**Acceptance criteria:**
- Empty data map → `nil`
- Data entries show type label and truncated sample
- Uses TypeVocabulary for type labels
- Uses Format.to_clojure for samples (TRN-002 limits)

**Blocked by:** #2, #6

**Blocks:** #11

---

### Issue #9: Namespace.User module

Render `user/` namespace section (prelude from previous turns).

**Requirements:**
- NS-003: `user/` namespace for LLM definitions
- NS-010: Turn 1: user/ section empty or omitted
- NS-011: Turn N+1: user/ shows accumulated definitions
- FMT-003: Header `;; === user/ (your prelude) ===`
- FMT-006 to FMT-010: Function and value formats
- DEF-001 to DEF-009: Definition handling rules
- SAM-001 to SAM-003: Samples vs output logic

**Files to create:**
- `lib/ptc_runner/sub_agent/namespace/user.ex`

**Complexity notes:**
- Must partition memory into functions vs values
- Functions need docstring + optional return type
- Values need type + optional sample (based on has_println)
- DEF-009: Functions first, then values

**Acceptance criteria:**
- Empty memory → `nil`
- Functions formatted with params, optional docstring, optional return type
- Values formatted with type, optional sample
- Docstrings sanitized (DEF-007)
- Order: functions first, then values (DEF-009)

**Blocked by:** #3, #6

**Blocks:** #11

---

### Issue #10: ExecutionHistory module

Render tool call history and println output sections.

**Requirements:**
- FMT-011 to FMT-015: Tool calls and output format
- FMT-016: Section ordering
- FMT-017: Summaries consolidated across turns
- FMT-018: Output rendered as-is
- TC-001 to TC-007: Tool call rules
- TRN-001 to TRN-007, TRN-010: Truncation rules

**Files to create:**
- `lib/ptc_runner/sub_agent/namespace/execution_history.ex`

**Acceptance criteria:**
- No tool calls → `;; No tool calls made`
- Tool calls rendered with truncated args
- FIFO when limit exceeded
- Output section shows println output (when has_println)
- Output lines not prefixed

**Blocked by:** #4

**Blocks:** #12

---

## Phase 4: Compression System

### Issue #11: Namespace coordinator module

Coordinate rendering of all three namespaces (tool/, data/, user/).

**Requirements:**
- FMT-016: Section order tool/ → data/ → user/
- Empty sections omitted

**Files to create:**
- `lib/ptc_runner/sub_agent/namespace.ex`

**Acceptance criteria:**
- Calls Tool, Data, User renderers in order
- Joins with blank lines
- Omits nil sections

**Blocked by:** #7, #8, #9

**Blocks:** #12

---

### Issue #12: Compression behaviour and normalize

Define Compression behaviour interface and option normalization.

**Requirements:**
- ARC-003: Compression behaviour with `to_messages/3` and `name/0`
- ARC-004: Compression is pure render function
- ARC-006: Turn count from `length(turns)`
- API-001 to API-007: Configuration options
- CMP-003: Compression at render time

**Files to create:**
- `lib/ptc_runner/sub_agent/compression.ex`

**Acceptance criteria:**
- `@behaviour` with callbacks defined
- `normalize/1` handles: nil, false, true, Module, {Module, opts}
- Returns `{strategy | nil, opts}` tuple

**Blocked by:** #5

**Blocks:** #13

---

### Issue #13: SingleUserCoalesced compression strategy

Default strategy that accumulates all context into single USER message.

**Requirements:**
- ARC-005: Default strategy
- MSG-001 to MSG-007: Message array transformation
- CMP-001, CMP-002: Compression rules
- ERR-001 to ERR-005: Error handling (conditional collapsing)
- API-004, API-005: Default limits (println: 15, tool_calls: 20)

**Files to create:**
- `lib/ptc_runner/sub_agent/compression/single_user_coalesced.ex`

**Complexity notes:**
- Split turns into successful vs failed
- Accumulate tool_calls and prints from successful turns
- Conditional error display (only if last turn failed)
- Build USER content: mission + namespaces + history + errors + turns_left
- Final turn message different from regular

**Acceptance criteria:**
- Returns `[%{role: :system, ...}, %{role: :user, ...}]`
- Mission appears first in USER message
- Namespaces rendered via Namespace module
- Failed turns: only most recent error shown (if still failing)
- Recovered: all errors collapsed
- "Turns left: N" or "FINAL TURN - ..." message

**Blocked by:** #10, #11, #12

**Blocks:** #21

---

## Phase 5: Module Renames

Each rename is atomic (one commit). Can be done in parallel or sequentially.

### Issue #14: Rename PtcRunner.Prompt → PtcRunner.Template ✅ COMPLETE

**Status:** ✅ Complete (PR created for #622)

**Requirements:**
- BRK-003: Module rename ✅
- BRK-004: Sigil `~PROMPT` → `~T` ✅
- CLN-002, CLN-003 ✅

**Files:**
- ✅ Renamed `lib/ptc_runner/prompt.ex` → `lib/ptc_runner/template.ex`
- ✅ Updated all references
- ✅ Updated sigil definition

**Blocked by:** #1 (complete)

**Blocks:** #22

---

### Issue #15: Rename SubAgent.Prompt → SubAgent.SystemPrompt

**Requirements:**
- BRK-005: Module rename
- CLN-004

**Files:**
- Rename `lib/ptc_runner/sub_agent/prompt.ex` → `lib/ptc_runner/sub_agent/system_prompt.ex`
- Update all references

**Blocked by:** #1

**Blocks:** #22

---

### Issue #16: Rename SubAgent.Template → SubAgent.MissionExpander

**Requirements:**
- BRK-006: Module rename
- CLN-005

**Files:**
- Rename `lib/ptc_runner/sub_agent/template.ex` → `lib/ptc_runner/sub_agent/mission_expander.ex`
- Update all references

**Blocked by:** #1

**Blocks:** #22

---

### Issue #17: Rename Lisp.Prompts → Lisp.LanguageSpec

**Requirements:**
- BRK-007: Module rename
- CLN-006

**Files:**
- Rename `lib/ptc_runner/lisp/prompts.ex` → `lib/ptc_runner/lisp/language_spec.ex`
- Update all references

**Acceptance criteria:**
- Module renamed and all references updated
- `LanguageSpec.get(:single_shot)` returns single-shot language spec
- `LanguageSpec.get(:multi_turn)` returns multi-turn language spec
- Existing API preserved under new name

**Blocked by:** #1

**Blocks:** #18, #22

---

### Issue #18: Prepare static SYSTEM prompt generator (no behavior change)

Create new function for static SYSTEM prompt generation. **Do NOT switch live behavior yet** - that happens atomically in Issue #22.

**Requirements:**
- ARC-008: SYSTEM prompt fully static (language spec + output format only)
- ARC-011: Static SYSTEM applies regardless of compression setting
- ARC-012: `compression` only affects turn history rendering

**Risk mitigation:** This issue creates the capability but does NOT change existing behavior. The `generate/2` function continues to work as before. The new `generate_static/2` function is added alongside.

**Files to modify:**
- `lib/ptc_runner/sub_agent/system_prompt.ex` (after rename)

**Acceptance criteria:**
- New `SystemPrompt.generate_static/2` function added
- Static prompt contains only PTC-Lisp language spec + output format
- No tools or data in static prompt
- **Existing `generate/2` unchanged** - agents continue working
- Tests for new function only

**Blocked by:** #15, #17

**Blocks:** #22

---

## Phase 6: API Changes

### Issue #19: Rename SubAgent.prompt → SubAgent.mission

**Requirements:**
- BRK-001: Field rename
- CLN-007, CLN-011

**Strategy:** Dual-field during transition

**Files to modify:**
- `lib/ptc_runner/sub_agent.ex`
- All SubAgent.new() call sites

**Acceptance criteria:**
- `SubAgent.new(mission: "...")` works
- `SubAgent.new(prompt: "...")` works during transition (then removed)
- Internal code uses `agent.mission`

**Blocked by:** #14-#17 (all renames complete)

**Blocks:** #22, #23

---

### Issue #20: Debug API changes

Update Debug API with new options and always-captured raw_response.

**Requirements:**
- BRK-008: `debug: true` no longer needed
- BRK-009: `messages:`, `system:` → `view:`, `raw:`
- DBG-003 to DBG-010: Debug API requirements
- CLN-008, CLN-009, CLN-010

**Files to modify:**
- `lib/ptc_runner/sub_agent/debug.ex`
- Remove debug option handling from Loop

**Acceptance criteria:**
- `print_trace(step)` shows programs + results
- `print_trace(step, raw: true)` includes raw_response
- `print_trace(step, view: :compressed)` shows compressed view
- `print_trace(step, usage: true)` adds token stats
- Old options removed

**Blocked by:** #5 (Turn struct)

**Blocks:** #23

---

## Phase 7: Integration

### Issue #21: Step.trace → Step.turns migration (dual-write only)

Add turns field alongside trace, update Loop to populate both. **Do NOT delete trace yet** - that happens in Issue #24 after demo migration.

**Requirements:**
- ARC-007: Step.turns replaces Step.trace (partial - dual-write phase)
- BRK-002: Field rename (partial)

**Risk mitigation:** Both `trace` and `turns` work during transition. Demo and other consumers can migrate at their own pace.

**Strategy:** Dual-write only (no deletion)

**Files to modify:**
- `lib/ptc_runner/step.ex`
- `lib/ptc_runner/sub_agent/loop.ex`

**Acceptance criteria:**
- Step has `turns` field (list of Turn)
- Step **still has `trace` field** (for backward compatibility)
- Loop creates Turn.success/Turn.failure after each cycle
- Loop populates **both** `trace` and `turns`
- Turns list is append-only
- All existing tests pass (trace still works)
- New tests for turns

**Blocked by:** #5, #13

**Blocks:** #22

---

### Issue #22a: Static SYSTEM + namespace injection (atomic switch)

**This is the atomic switch** - the truly critical integration point:
1. Switches to static SYSTEM prompt (from #18)
2. Injects tool/ and data/ namespaces into USER message

No compression wiring yet - that's #22b. This keeps the blast radius small.

**Requirements:**
- ARC-009: Tools and data in USER message
- ARC-011: Static SYSTEM prompt applies regardless of compression setting
- UCM-001 to UCM-010: Uncompressed mode behavior
- MSG-006: SYSTEM static text unchanged

**Risk mitigation:** Both the static SYSTEM and namespace injection happen together - no "blind LLM" gap. Compression is deferred to #22b.

**Files to modify:**
- `lib/ptc_runner/sub_agent/loop.ex`

**Acceptance criteria:**
- Loop uses `SystemPrompt.generate_static/2` (new prompt structure)
- Tool/ and data/ namespaces rendered in first USER message via Namespace module
- **Agents work correctly** - tools visible to LLM via USER message
- First USER contains: mission + tool/ + data/ namespaces
- Turn history as USER/ASSISTANT pairs (unchanged from current behavior)
- ASSISTANT messages contain full program code
- USER feedback messages contain: Result/Error + println output + turns left
- Full error shown (no conditional collapsing)

**Blocked by:** #18, #19, #21

**Blocks:** #22b

---

### Issue #22b: Wire compression strategy

Add compression support on top of the stable #22a foundation.

**Requirements:**
- API-001 to API-003: compression option
- ARC-012: compression option only affects turn history rendering
- SS-001, SS-002: Single-shot mode handling
- CMP-003: Compression at render time

**Files to modify:**
- `lib/ptc_runner/sub_agent/loop.ex`
- `lib/ptc_runner/sub_agent.ex` (add compression option)

**Acceptance criteria:**
- `compression: true` uses SingleUserCoalesced for history
- `compression: {Strategy, opts}` uses custom strategy
- `compression: false` (default) uses uncompressed mode from #22a
- `max_turns: 1` skips history compression
- Messages built via strategy.to_messages/3

**Blocked by:** #13, #22a

**Blocks:** #23

---

## Phase 8: Demo Migration

### Issue #23: Demo application migration

Update demo/ to use new API and verify everything works.

**Requirements:**
- MIG-001 to MIG-006: All demo migration items

**Files to modify:**
- `demo/lib/demo/agent.ex`
- `demo/lib/demo/prompts.ex`
- `demo/lib/demo/cli_base.ex`
- `demo/lib/demo/*_cli.ex`

**Acceptance criteria:**
- All `prompt:` → `mission:`
- All `step.trace` → `step.turns`
- All `Lisp.Prompts` → `Lisp.LanguageSpec`
- `print_trace` uses new options
- Demo runs successfully with compression enabled
- E2E tests pass

**Blocked by:** #19, #20, #22

**Blocks:** #24

---

## Phase 9: Final Cleanup

### Issue #24: Final cleanup - delete deprecated code

Delete all deprecated fields and dual-write code after all consumers have migrated.

**Requirements:**
- BRK-002: Field rename (completion)
- CLN-001: Delete Step.trace field
- CLN-011: Delete opts[:prompt] fallback
- CLN-012: Delete dual-write code

**Risk mitigation:** Only runs after demo migration (#23) is complete and verified. All consumers use new API.

**Files to modify:**
- `lib/ptc_runner/step.ex` (remove trace field)
- `lib/ptc_runner/sub_agent.ex` (remove prompt fallback)
- `lib/ptc_runner/sub_agent/loop.ex` (remove dual-write)
- `lib/ptc_runner/migration_guard.ex` (uncomment CLN-001 guard)

**Acceptance criteria:**
- `Step.trace` field deleted
- `Step` only has `turns` field for history
- `opts[:prompt]` fallback removed from SubAgent.new/1
- Dual-write code removed from Loop
- MigrationGuard CLN-001 uncommented and passes
- All tests pass
- E2E tests pass
- Documentation updated to reflect final API (deferred from earlier issues)
- Remove "Current Work" section from CLAUDE.md

**Blocked by:** #23

**Blocks:** None (final issue)

---

## Dependency Graph

```
#1 (PRE-001: Messages in Step) ✅
├── #2 (Namespace auto-fallback)
│   ├── #7 (Namespace.Tool)
│   └── #8 (Namespace.Data) ──┐
├── #3 (Return type capture)   │
│   └── #9 (Namespace.User) ◄──┤
├── #4 (println capture)       │
│   └── #10 (ExecutionHistory) │
├── #5 (Turn struct)           │
│   ├── #12 (Compression behaviour)
│   │   └── #13 (SingleUserCoalesced) ◄── #10, #11
│   ├── #20 (Debug API)        │
│   └── #21 (Step.turns dual-write)
├── #6 (TypeVocabulary)        │
│   ├── #8 ────────────────────┤
│   └── #9 ────────────────────┘
├── #14-#16 (Module renames)
├── #17 (LanguageSpec + get/1 API)
│   └── #18 (Prepare static SYSTEM) ◄── #15, #17
│       └── #19 (prompt→mission) ◄── #14-#17
│           └── #22 (Wire compression - ATOMIC SWITCH) ◄── #13, #18, #19, #21
│               └── #23 (Demo migration) ◄── #20, #22
│                   └── #24 (Final cleanup) ◄── #23
```

**Critical path:** #1 → #5 → #12 → #13 → #22 → #23 → #24

---

## Parallel Work Opportunities

These issue groups can be worked on in parallel:

| Track A | Track B | Track C |
|---------|---------|---------|
| #2 (auto-fallback) | #5 (Turn) | #14-#17 (renames) |
| #7, #8 (Tool, Data) | #6 (TypeVocabulary) | |
| | #9 (User) | |

After convergence at #11-#13, work becomes more sequential.

---

## Estimated Complexity

| Issue | Size | Notes |
|-------|------|-------|
| #1 | M | Existing issue |
| #2 | L | Core Lisp changes, high regression risk |
| #3 | S | Metadata capture |
| #4 | S | println capture |
| #5 | S | New struct |
| #6 | S | Pure functions |
| #7 | S | Simple rendering |
| #8 | S | Simple rendering |
| #9 | M | Complex formatting logic |
| #10 | M | Limits and truncation |
| #11 | S | Coordinator only |
| #12 | S | Behaviour + normalize |
| #13 | L | Core compression logic |
| #14-#16 | XS each | Search-replace |
| #17 | S | Rename + verify get/1 API |
| #18 | S | New function only, no behavior change |
| #19 | S | Dual-field pattern |
| #20 | M | API changes + tests |
| #21 | M | Dual-write only (no deletion) |
| #22 | L | Critical integration, atomic switch |
| #23 | M | Demo updates + E2E |
| #24 | S | Cleanup only |

**Legend:** XS = <1h, S = 1-2h, M = 2-4h, L = 4-8h

---

## Risks Addressed

| Risk | Mitigation |
|------|------------|
| **"Blind LLM" Gap** - Issue #18 removes tools from SYSTEM before #22 injects them in USER | #18 creates capability only (`generate_static/2`), actual switch happens atomically in #22 |
| **Breaking Demo** - Deleting `Step.trace` before demo migrates | #21 is dual-write only; deletion moved to #24 (after demo migration) |
| **Implicit Behavior Change** - Unclear if `compression: false` also changes prompt structure | Added ARC-011, ARC-012: prompt structure is universal, compression only affects history |
| **Missing API** - Issue #17 rename doesn't verify `get/1` API | Added acceptance criteria for `LanguageSpec.get(:single_shot)` and `get(:multi_turn)` |
| **PTC-Lisp Regressions** - Issue #2 modifies core eval/env logic | Added required edge case tests: shadowing, nil values, ambiguous references |

---

## Notes for Issue Creation

1. Each issue should reference the requirement IDs it implements
2. Include acceptance criteria from this document
3. Link blocking/blocked-by relationships
4. Add CLN-* requirements as checkboxes in cleanup issues
5. Consider creating an Epic to group all issues
6. Add `breaking-change` label to issues with BRK-* requirements
7. Add `high-risk` label to issues #2 and #22
