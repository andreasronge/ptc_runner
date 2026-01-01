# Documentation Migration Plan

> **Status:** Draft
> **Goal:** Consolidate SubAgent docs into module docs and guides

This plan migrates documentation from `docs/ptc_agents/` to appropriate locations:
- API reference → Elixir module `@moduledoc`/`@doc`
- Conceptual guides → `docs/guides/`
- Design decisions → `docs/guidelines/`
- Obsolete docs → Delete

## Principles

1. **Single source of truth**: No duplicate content
2. **Discoverable**: Users find docs via HexDocs, not markdown spelunking
3. **Maintainable**: Docs live near code they describe
4. **Independent tasks**: Each task can be done in isolation

---

## Writing Style Guide

Follow Elixir ecosystem conventions (see [Writing Documentation](https://hexdocs.pm/elixir/writing-documentation.html)).

### Tone

- **Approachable but technical**: Explain "why" alongside "how"
- **Direct**: Use imperative mood ("Run the command" not "You should run")
- **Collaborative**: "Let's" for walkthroughs, but not overused
- **No fluff**: Avoid "simply", "just", "easily" - if it were simple, they wouldn't need docs

### Structure

**First paragraph is critical:**
> Keep the first paragraph concise and simple, typically one line. Tools extract this for summaries.

```elixir
@doc """
Executes a SubAgent and returns the result.

Takes a prompt or SubAgent struct and runs it through the agentic loop
until completion or failure.

## Examples

    iex> SubAgent.run("Count to 3", llm: my_llm)
    {:ok, %Step{return: 3}}

## Options

  * `:llm` - Required. The LLM callback function.
  * `:context` - Data available as `ctx/` in programs.

"""
```

**Section order for `@moduledoc`:**
1. One-line summary
2. Overview paragraph (2-3 sentences)
3. `## Examples` - show, don't tell
4. Detailed sections as needed
5. `## Options` or configuration (if applicable)

**Section order for guides:**
1. What this guide covers (1-2 sentences)
2. Prerequisites (if any)
3. Content sections (progressive complexity)
4. Further reading / cross-links

### Formatting

| Element | Convention |
|---------|------------|
| Module refs | `` `PtcRunner.SubAgent` `` (full path, backticks) |
| Function refs | `` `run/2` `` local, `` `SubAgent.run/2` `` external |
| Type refs | `` `t:Step.t/0` `` |
| Callback refs | `` `c:llm_callback/1` `` |
| Code examples | `iex>` prompt for interactive, plain block for scripts |
| Options | Bullet list with `:option` - Description format |
| Headings | `##` for sections (never `#`, reserved for title) |

### Code Examples

**Do:**
```elixir
## Examples

    iex> SubAgent.run("Hello", llm: fn _ -> {:ok, "(return 42)"} end)
    {:ok, %Step{return: 42}}
```

**Don't:**
```elixir
## Examples

```elixir
# This won't work as a doctest
SubAgent.run("Hello", llm: my_llm)
```
```

### Paragraphs

- **Short**: 2-4 sentences max
- **One idea per paragraph**
- **Lead with the point**: Don't bury the important info

### Admonitions

Use sparingly. Prefer inline notes:

```markdown
> **Note:** This requires `max_turns > 1` to take effect.
```

Or prefix style for warnings:

```markdown
**Warning:** This will delete all data. Use with caution.
```

### What NOT to Document

- Implementation details (use code comments instead)
- Private functions (use `@doc false`)
- Obvious behavior ("Returns the result" for a function called `get_result`)
- Future plans or TODOs

### Cross-References

Always link to related content:

```markdown
See `SubAgent.run/2` for execution details.

For chaining patterns, see the [Patterns Guide](guides/subagent-patterns.md).
```

### Guides vs Module Docs

| Guides (`docs/guides/`) | Module Docs (`@moduledoc`) |
|-------------------------|---------------------------|
| Conceptual, tutorial-style | API reference |
| Progressive learning path | Complete but concise |
| Multiple modules involved | Single module focus |
| "How to achieve X" | "What does Y do" |
| Can include context/motivation | Focused on usage |

### Brevity

**Guides are not exhaustive references.** Show the core pattern, then point elsewhere.

| Content | Where it belongs |
|---------|------------------|
| Core concept + 1-2 examples | Guide |
| All options/parameters | Module docs (`@doc`) |
| Edge cases, error handling | Module docs or skip |
| Internal behavior | Skip (or code comments) |

**Rule of thumb:** If a section exceeds 30 lines, split it or move details to module docs.

**Prefer linking over explaining:**
```markdown
<!-- Don't: restate module docs -->
The `max_turns` option limits iterations. Default is 10. When exceeded...

<!-- Do: show usage, link for details -->
Limit iterations with `max_turns`. See `PtcRunner.SubAgent.run/2` for all options.
```

### Audience

**Guides are for library users**, not library contributors.

- Show patterns for building applications with PtcRunner
- Use `MyApp.*` namespaces in examples (not `PtcRunner.*` internals)
- Focus on public API usage, not internal implementation
- Assume readers have installed PtcRunner as a dependency

**Do not include:**
- How the library implements features internally
- References to internal modules or private functions
- Test patterns for the library's own test suite
- Contributor workflows (those belong in CONTRIBUTING.md or `docs/guidelines/`)

### File Naming Conventions

| Location | Pattern | Example |
|----------|---------|---------|
| SubAgent guides | `subagent-<topic>.md` | `subagent-testing.md` |
| General guides | `<topic>.md` | `signatures.md` |
| Guidelines | `<topic>-guidelines.md` | `testing-guidelines.md` |
| Reference docs | `ptc-<dsl>-*.md` | `ptc-lisp-specification.md` |

### Guide Checklist

Before merging a new guide, verify:

- [ ] First line is a one-sentence summary (no heading)
- [ ] Prerequisites section (if any assumed knowledge)
- [ ] All code examples use `MyApp.*` namespaces
- [ ] No references to private/internal modules
- [ ] "See Also" section with cross-links
- [ ] Added to `mix.exs` extras (for HexDocs)
- [ ] All internal links resolve correctly

### Common Anti-Patterns

**Don't:** Start with context or motivation
```markdown
# Testing SubAgents

SubAgents are a powerful feature that allow LLMs to...
(3 paragraphs of background)
```

**Do:** Start with what the guide covers
```markdown
# Testing SubAgents

Strategies for testing SubAgent-based code: mocking LLMs, testing tools, and integration testing.
```

---

**Don't:** Use library internals in examples
```elixir
# Bad - exposes internal module
PtcRunner.SubAgent.Loop.execute(agent)
```

**Do:** Use public API only
```elixir
# Good - public API
SubAgent.run(agent, llm: my_llm)
```

---

**Don't:** Document implementation details
```markdown
The loop uses `Process.send_after/3` internally to handle timeouts...
```

**Do:** Document behavior and usage
```markdown
Set `:timeout` to limit execution time. Default is 30 seconds.
```

---

## Phase 1: Delete Obsolete Docs

No dependencies. Can be done immediately.

### Task 1.1: Delete historical/planning docs

**Files to delete:**
- `docs/ptc_agents/implementation_plan.md` - Implementation complete
- `docs/ptc_agents/spike-summary.md` - Historical spike validation
- `docs/ptc_agents/lisp-api-updates.md` - Breaking changes already applied
- `docs/ptc_agents/README.md` - Says "Planning phase", obsolete
- `docs/ptc_agents/guides/README.md` - Says "not yet implemented"

**Verification:** `git log` preserves history if needed later.

---

## Phase 2: Migrate Guides

Each guide migration is independent. Update internal links as you go.

### Task 2.1: Migrate getting-started guide

**Source:** `docs/ptc_agents/guides/getting-started.md`
**Target:** `docs/guides/subagent-getting-started.md`

**Actions:**
1. Copy file to new location
2. Update status (remove "not yet implemented" notes)
3. Update internal links to new paths
4. Delete source file

### Task 2.2: Migrate core-concepts guide

**Source:** `docs/ptc_agents/guides/core-concepts.md`
**Target:** `docs/guides/subagent-concepts.md`

**Actions:**
1. Copy file to new location
2. Update internal links
3. Delete source file

### Task 2.3: Migrate patterns guide

**Source:** `docs/ptc_agents/guides/patterns.md`
**Target:** `docs/guides/subagent-patterns.md`

**Actions:**
1. Copy file to new location
2. Update internal links
3. Delete source file

### Task 2.4: Migrate advanced guide

**Source:** `docs/ptc_agents/guides/advanced.md`
**Target:** `docs/guides/subagent-advanced.md`

**Actions:**
1. Copy file to new location
2. Update internal links
3. Delete source file

### Task 2.5: Merge signatures guide into reference

**Source:** `docs/ptc_agents/guides/signatures.md`
**Target:** Merge into `docs/ptc_agents/signature-syntax.md`

**Actions:**
1. Review both files for overlap
2. Add any unique content from guides/signatures.md to signature-syntax.md
3. Delete `docs/ptc_agents/guides/signatures.md`
4. Move `signature-syntax.md` to `docs/signature-syntax.md`

### Task 2.6: Delete empty guides folder

**Depends on:** 2.1-2.5 complete

**Action:** `rm -rf docs/ptc_agents/guides/`

---

## Phase 3: Migrate to Module Docs

Each module migration is independent. These are the largest tasks.

### Task 3.1: Migrate Step docs to module

**Source:** `docs/ptc_agents/step.md`
**Target:** `lib/ptc_runner/step.ex` `@moduledoc`

**Actions:**
1. Read current `Step` module docs
2. Merge step.md content into `@moduledoc`
3. Add `@doc` to individual functions if needed
4. Ensure doctests work
5. Delete `docs/ptc_agents/step.md`

**Content to migrate:**
- Struct definition and field descriptions
- `fail` type specification
- `usage` type specification
- Error reasons table
- Usage patterns/examples

### Task 3.2: Migrate type-coercion-matrix to module

**Source:** `docs/ptc_agents/type-coercion-matrix.md`
**Target:** `lib/ptc_runner/sub_agent/signature/coercion.ex` `@moduledoc`

**Actions:**
1. Add coercion matrix table to module doc
2. Add examples as doctests where possible
3. Delete source file

### Task 3.3: Migrate system-prompt-template to module

**Source:** `docs/ptc_agents/system-prompt-template.md`
**Target:** `lib/ptc_runner/sub_agent/prompt.ex` `@moduledoc`

**Actions:**
1. Document prompt structure in moduledoc
2. Document customization options
3. Delete source file

### Task 3.4: Migrate parallel-trace-design to module

**Source:** `docs/ptc_agents/parallel-trace-design.md`
**Target:** `lib/ptc_runner/tracer.ex` `@moduledoc` (or relevant module)

**Actions:**
1. Document trace structure in moduledoc
2. Document merge/aggregation behavior
3. Delete source file

### Task 3.5: Migrate SubAgent API docs from specification.md

**Source:** `docs/ptc_agents/specification.md` (sections)
**Target:** `lib/ptc_runner/sub_agent.ex` and related modules

**Actions:**
1. Move `new/1` docs to `@doc` on `SubAgent.new/1`
2. Move `run/2` docs to `@doc` on `SubAgent.run/2`
3. Move `run!/2`, `then!/2` docs to respective functions
4. Move `as_tool/2` docs to function
5. Move `compile/2` docs to function
6. Move `preview_prompt/2` docs to function
7. Update moduledoc with overview

**Note:** This is the largest task. Consider splitting by function.

### Task 3.6: Migrate LLMTool docs from specification.md

**Source:** `docs/ptc_agents/specification.md` (LLMTool section)
**Target:** `lib/ptc_runner/sub_agent/llm_tool.ex` `@moduledoc`

**Actions:**
1. Document struct fields
2. Document `:caller` vs explicit LLM
3. Add examples
4. Remove section from specification.md

### Task 3.7: Migrate Loop docs from specification.md

**Source:** `docs/ptc_agents/specification.md` (Execution Loop, System Tools)
**Target:** `lib/ptc_runner/sub_agent/loop.ex` `@moduledoc`

**Actions:**
1. Document loop behavior
2. Document system tools (return/fail)
3. Document turn handling
4. Remove section from specification.md

### Task 3.8: Migrate Debug docs from specification.md

**Source:** `docs/ptc_agents/specification.md` (Debugging & Introspection)
**Target:** `lib/ptc_runner/sub_agent/debug.ex` `@moduledoc`

**Actions:**
1. Document debug mode
2. Document trace structure
3. Document print_trace/print_chain
4. Remove section from specification.md

---

## Phase 4: Extract Design Decisions

Single task, can be done anytime.

### Task 4.1: Create design-decisions guideline

**Source:** `docs/ptc_agents/specification.md` (Design Decisions section)
**Target:** `docs/guidelines/design-decisions.md`

**Actions:**
1. Extract DD-1 through DD-13
2. Format as ADR-style document
3. Add context/rationale where missing
4. Remove section from specification.md

---

## Phase 5: Cleanup

### Task 5.1: Delete or minimize specification.md

**Depends on:** Phase 3 and 4 complete

**Actions:**
1. Review remaining content in specification.md
2. If anything remains, move to appropriate location
3. Delete `docs/ptc_agents/specification.md`

### Task 5.2: Delete ptc_agents folder

**Depends on:** All above complete

**Actions:**
1. Verify folder is empty (or only has this plan)
2. Delete `docs/ptc_agents/`
3. Delete this migration plan

### Task 5.3: Update CLAUDE.md references

**Actions:**
1. Update any references to `docs/ptc_agents/`
2. Point to new guide locations

### Task 5.4: Update cross-references in remaining docs

**Actions:**
1. Search for links to deleted/moved files
2. Update to new locations

---

## Task Dependency Graph

```
Phase 1 (Delete obsolete)
    └── Task 1.1 ──────────────────────────────────────┐
                                                        │
Phase 2 (Migrate guides)                               │
    ├── Task 2.1 (getting-started) ────────────────────┤
    ├── Task 2.2 (core-concepts) ──────────────────────┤
    ├── Task 2.3 (patterns) ───────────────────────────┤
    ├── Task 2.4 (advanced) ───────────────────────────┤
    ├── Task 2.5 (signatures) ─────────────────────────┤
    └── Task 2.6 (delete guides/) ─── depends on 2.1-2.5
                                                        │
Phase 3 (Migrate to modules) ──── all independent ─────┤
    ├── Task 3.1 (Step)                                │
    ├── Task 3.2 (Coercion)                            │
    ├── Task 3.3 (Prompt)                              │
    ├── Task 3.4 (Tracer)                              │
    ├── Task 3.5 (SubAgent API)                        │
    ├── Task 3.6 (LLMTool)                             │
    ├── Task 3.7 (Loop)                                │
    └── Task 3.8 (Debug)                               │
                                                        │
Phase 4 (Design decisions) ────────────────────────────┤
    └── Task 4.1 (extract DDs)                         │
                                                        │
Phase 5 (Cleanup) ─────────────── depends on all above─┘
    ├── Task 5.1 (delete specification.md) ─── after 3.5-3.8, 4.1
    ├── Task 5.2 (delete ptc_agents/) ─── after all
    ├── Task 5.3 (update CLAUDE.md)
    └── Task 5.4 (update cross-refs)
```

---

## Parallel Execution Groups

These tasks can be done simultaneously by different people/sessions:

**Group A (Delete + Guides):** 1.1, 2.1, 2.2, 2.3, 2.4, 2.5
**Group B (Module docs):** 3.1, 3.2, 3.3, 3.4
**Group C (Spec breakdown):** 3.5, 3.6, 3.7, 3.8, 4.1
**Group D (Cleanup):** 5.3, 5.4 (can start early, finish after others)

---

## Estimated Effort

| Task | Size | Notes |
|------|------|-------|
| 1.1 | S | Just delete files |
| 2.1-2.5 | S each | Copy, update links |
| 3.1 | M | Step struct is well-defined |
| 3.2 | S | Coercion matrix is a table |
| 3.3 | M | Prompt template has details |
| 3.4 | M | Trace design is complex |
| 3.5 | L | Largest - consider splitting |
| 3.6 | S | LLMTool is focused |
| 3.7 | M | Loop has multiple concepts |
| 3.8 | S | Debug is focused |
| 4.1 | M | 13 design decisions |
| 5.x | S each | Cleanup tasks |

**Total: ~15-20 small-to-medium tasks**

---

## Phase 6: Restructure Top-Level Docs

SubAgent is the main API. README and top-level docs should reflect this.

### Task 6.0: Rewrite README.md

**Goal:** Lead with SubAgent, demote low-level APIs

**New structure:**
1. One-line description (LLM agents that write programs)
2. Quick Start - SubAgent example (10 lines)
3. Why SubAgents? - 4 bullet points
4. Installation
5. Documentation links (to guides, not specs)
6. Low-Level APIs - brief mention of Lisp/JSON
7. License

**Remove:**
- JSON DSL example from hero position
- "Why two DSLs?" section (move to appendix)
- Detailed feature list (move to guide)

### Task 6.1: Simplify guide.md

**Current:** 200+ lines of architecture, low-level API
**Target:** Brief overview pointing to SubAgent

**New structure:**
1. What is PtcRunner? (SubAgent focus)
2. Architecture diagram (keep, simplify)
3. Low-Level APIs (brief, for advanced users)
4. Links to SubAgent guides

### Task 6.2: Demote PTC-JSON docs

**Actions:**
- Move `ptc-json-specification.md` to `docs/reference/` or `docs/appendix/`
- Remove from main documentation links
- Add note: "JSON DSL is not supported in SubAgent API"

### Task 6.3: Consolidate PTC-Lisp docs

**Current:** Three files with overlap
- `ptc-lisp-overview.md` - Introduction
- `ptc-lisp-specification.md` - Full spec
- `ptc-lisp-llm-guide.md` - API + LLM prompt (special file)

**Key insight:** The prompt section in `ptc-lisp-llm-guide.md` is NOT documentation -
it's a compiled resource. It should live in `priv/`, not `docs/`.

**Targets:**
- LLM prompt → `priv/prompts/ptc-lisp-reference.md`
- Developer API docs → `PtcRunner.Lisp` `@moduledoc`
- Language overview → brief section in guide or delete

**Actions:**

1. **Extract prompt to `priv/prompts/ptc-lisp-reference.md`**
   - Create `priv/prompts/` directory
   - Move content between `<!-- PTC_PROMPT_START -->` and `<!-- PTC_PROMPT_END -->`
   - Keep the markers in the new file
   - Add header: "PTC-Lisp Language Reference (for LLM prompts)"

2. **Update extraction path in `lib/ptc_runner/lisp/schema.ex`** (lines 10, 14)
   - Change path to `priv/prompts/ptc-lisp-reference.md`
   - Verify `mix compile` succeeds

3. **Move API docs to module**
   - Move options table, return values, agentic loop example to `PtcRunner.Lisp` `@moduledoc`
   - Delete developer-facing sections from the llm-guide file

4. **Delete redundant docs**
   - Delete `docs/ptc-lisp-llm-guide.md` (content now split)
   - Delete `docs/ptc-lisp-overview.md` (merge unique bits into moduledoc)
   - Keep `docs/ptc-lisp-specification.md` as `docs/reference/ptc-lisp-spec.md` OR delete if covered by moduledoc

5. **Verify**
   - `mix compile` succeeds
   - `PtcRunner.Lisp.Schema.to_prompt()` returns expected content
   - HexDocs renders correctly

**Future:** The `priv/prompts/` directory can hold other prompt resources:
- `priv/prompts/subagent-system.md` - SubAgent system prompt template (if extracted from code)
- `priv/prompts/ptc-json-reference.md` - JSON DSL reference (if needed)

---

## Phase 7: New Guides

These can be done in parallel with other phases. Each is independent.

### Task 7.1: Create testing guide ✓

**Target:** `docs/guides/subagent-testing.md`
**Status:** Done (created as template)

**Content:**
- Mocking the LLM callback
- Testing tools in isolation
- Snapshot testing with `preview_prompt/2`
- Integration testing (gated by env var)
- Testing error paths and recovery

### Task 7.2: Create tool development guide

**Target:** `docs/guides/subagent-tools.md`

**Content:**
- Anatomy of a good tool (signature + description)
- When to use @spec/@doc vs explicit signatures
- Error handling in tools
- Stateful tools and side effects
- Tools that call external APIs

### Task 7.3: Create troubleshooting guide

**Target:** `docs/guides/subagent-troubleshooting.md`

**Content:**
- Agent loops forever (max_turns, missing return)
- Validation errors (signature mismatches)
- Tool not being called (description quality)
- Context too large (firewall, prompt_limit)
- LLM returning prose instead of code

### Task 7.4: Create cookbook/examples guide

**Target:** `docs/guides/subagent-cookbook.md`

**Content:**
- Email triage and response
- Data analysis pipeline
- Document summarization
- Multi-step research agent
- Parallel processing pattern

---

## Updated Task Dependency Graph

```
Phase 1 (Delete obsolete)
    └── Task 1.1 ──────────────────────────────────────┐
                                                        │
Phase 2 (Migrate guides)                               │
    ├── Task 2.1-2.5 (all independent) ────────────────┤
    └── Task 2.6 (delete guides/) ─── depends on 2.1-2.5
                                                        │
Phase 3 (Migrate to modules) ──── all independent ─────┤
    └── Tasks 3.1-3.8                                  │
                                                        │
Phase 4 (Design decisions) ────────────────────────────┤
    └── Task 4.1                                       │
                                                        │
Phase 5 (Cleanup) ─────────────── depends on 1-4 ──────┘
    └── Tasks 5.1-5.4

Phase 6 (Restructure top-level) ── after Phase 2 ──────
    ├── Task 6.0 (README) ─── after guides exist
    ├── Task 6.1 (guide.md)
    ├── Task 6.2 (demote JSON)
    └── Task 6.3 (consolidate Lisp)

Phase 7 (New guides) ──────────── independent ─────────
    ├── Task 7.1 (testing) ✓
    ├── Task 7.2 (tool development)
    ├── Task 7.3 (troubleshooting)
    └── Task 7.4 (cookbook)
```

---

## Updated Parallel Execution Groups

**Group A (Delete + Migrate guides):** 1.1, 2.1-2.5
**Group B (Module docs):** 3.1-3.4
**Group C (Spec breakdown):** 3.5-3.8, 4.1
**Group D (Cleanup):** 5.1-5.4 (after A-C)
**Group E (Restructure):** 6.0-6.3 (after Group A)
**Group F (New guides):** 7.1-7.4 (anytime, independent)

---

## Success Criteria

- [ ] `docs/ptc_agents/` folder deleted
- [ ] README leads with SubAgent, not JSON DSL
- [ ] All SubAgent modules have comprehensive `@moduledoc`
- [ ] All public functions have `@doc` with examples
- [ ] Guides in `docs/guides/` are up-to-date and brief
- [ ] Design decisions documented in guidelines
- [ ] PTC-JSON demoted to reference/appendix
- [ ] PTC-Lisp consolidated to single reference file
- [ ] No broken internal links
- [ ] HexDocs renders correctly
- [ ] New guides created: testing, tools, troubleshooting, cookbook
