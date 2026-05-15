# Prompt Contracts and Profiles

| Field | Value |
|---|---|
| Status | Draft |
| Date | 2026-05-15 |
| Target packages | `:ptc_runner`, `:ptc_runner_mcp` |
| Related | `Plans/text-mode-ptc-compute-tool.md`, `Plans/ptc-lisp-tool-call-transport.md`, `Plans/ptc-runner-mcp-server.md`, `Plans/ptc-runner-mcp-aggregator.md`, `Plans/ptc-runner-mcp-catalog-exposure.md`, `Plans/ptc-runner-mcp-slim-responses.md`, `Plans/agentic-ptc-task-subagent-spec.md` |

## 1. Summary

Define a shared prompt contract vocabulary and migration path for the
prompt surfaces in `ptc_runner` and `ptc_runner_mcp`.

The repository currently has several prompt assembly paths:

- SubAgent PTC-Lisp prompts composed from `priv/prompts/` via
  `PtcRunner.Lisp.LanguageSpec`.
- Text-mode prompts for raw text, JSON output, and native tool use.
- Combined text/PTC-Lisp mode, which appends a compact
  `ptc_lisp_execute` reference card.
- MCP `ptc_lisp_execute` descriptions and authoring cards under
  `mcp_server/priv/`.
- MCP agentic `ptc_task` planner prompts assembled in
  `PtcRunnerMcp.Agentic.Prompt`.

These surfaces are allowed to live in different packages and file
trees. The goal is not one global prompt folder. The goal is a common
set of prompt contract dimensions, stable ordering rules, and tests
that prevent accidental drift while preserving package boundaries.

## 2. Motivation

Prompt drift is now a real maintenance cost. Similar guidance appears
in multiple places with slightly different wording and, more
importantly, sometimes different semantics.

Examples:

- Direct MCP aggregator `ptc_lisp_execute` uses `(tool/mcp-call ...)`
  where world-fault failures return `nil`.
- Agentic `ptc_task` uses an internal `tool/mcp-call` contract where
  results are tagged maps with `:ok`, `:value`, `:reason`, and
  `:message`.
- Combined text mode has a compact PTC-Lisp reference card that
  overlaps with the full SubAgent PTC-Lisp reference but also includes
  cache-bridge guidance that does not apply elsewhere.
- MCP tool descriptions can become too large for clients that truncate
  tool search/description text, so the first chunk of an advertised
  description must be sufficient for first successful use.

The MCP server may also move to its own git repository. Prompt
architecture should therefore avoid private-file coupling from
`mcp_server` into `ptc_runner` internals.

## 3. Goals

1. Make prompt dimensions explicit enough that adding a new prompt
   surface is a composition decision, not prose copy-paste.
2. Keep `ptc_runner` and `ptc_runner_mcp` prompt files independently
   owned so the MCP server can be split into a separate repository.
3. Preserve existing public behavior while introducing internal prompt
   renderer/profile concepts.
4. Shorten MCP advertised descriptions where needed, especially
   `ptc_lisp_execute` in aggregator mode, without losing first-call
   usability.
5. Prevent semantic drift between similar-looking contracts, especially
   direct aggregator MCP calls vs agentic planner MCP calls.
6. Add size-aware prompt profiles/budgets without confusing them with
   existing truncation options.
7. Keep operator/user customization points clear and safe.

## 4. Non-Goals

- No immediate removal of `ptc_reference: :compact`.
- No implementation of `ptc_reference: :full` in this spec.
- No single shared prompt directory across both packages.
- No requirement that `mcp_server` imports private prompt markdown from
  `ptc_runner`.
- No LLM-generated or semantic summarization of prompts.
- No behavioral rewrite of PTC-Lisp, MCP aggregator execution, catalog
  discovery, or agentic planning.
- No promise of byte-for-byte prompt stability after a future explicit
  prompt cleanup PR, except where compatibility tests intentionally pin
  current output.

## 5. Ownership Boundaries

### 5.1 `ptc_runner`

`ptc_runner` owns in-process SubAgent prompt surfaces:

- Core PTC-Lisp dialect guidance.
- SubAgent language behavior profiles such as single-shot and
  explicit-return multi-turn.
- In-process `ptc_lisp_execute` transport guidance.
- Combined text/PTC-Lisp mode reference guidance.
- Local app-tool exposure and cache-bridge guidance.
- Dynamic namespace, data, memory, tool inventory, and expected-output
  rendering.

### 5.2 `ptc_runner_mcp`

`ptc_runner_mcp` owns MCP-specific prompt and description surfaces:

- MCP `ptc_lisp_execute` advertised descriptions.
- Direct MCP no-tools authoring guidance.
- Direct MCP aggregator `(tool/mcp-call ...)` guidance.
- MCP response profile notes (`slim`, `structured`, `debug`).
- MCP catalog inline/lazy discovery guidance.
- MCP session authoring guidance.
- Agentic `ptc_task` planner prompts and tool descriptions.
- MCP trust-boundary guidance for upstream catalogs, tool
  descriptions, and payloads.

### 5.3 Sharing Contract

If `mcp_server` is split into a separate repository, it may depend on
`ptc_runner` as a library, but it must not read prompt files from
`ptc_runner` by private filesystem path.

Acceptable sharing patterns:

- Stable public API, for example a future
  `PtcRunner.PromptContracts.dialect(:compact)` function.
- Versioned copied snippets in MCP with tests pinning critical
  semantics.
- Shared documentation of contract dimensions and invariants.

Unacceptable sharing patterns:

- `mcp_server` importing `priv/prompts/*.md` directly by relative path.
- One package modifying another package's prompt ordering implicitly.
- A single global prompt renderer that cannot be extracted with
  `mcp_server`.

## 6. Prompt Contract Dimensions

Prompt surfaces should be described with these dimensions.

### 6.1 `dialect`

The PTC-Lisp language and sandbox guidance:

- Clojure-style forms, not Common Lisp or JavaScript.
- `let` vector bindings, not `let*` or parenthesized bindings.
- `fn`, not `lambda`.
- JSON helpers and string helper names.
- Mutable state and I/O restrictions.
- Java interop availability when relevant.

This dimension is mostly shared conceptually, but individual packages
may maintain their own compact/full wording.

### 6.2 `execution_surface`

How the model is expected to access computation or tools:

- `subagent_content`: model emits one fenced PTC-Lisp code block.
- `subagent_ptc_tool_call`: model calls native `ptc_lisp_execute`.
- `text_native_tools`: model uses provider-native app tools and
  returns text/JSON.
- `combined_text_ptc`: model can answer directly or call
  `ptc_lisp_execute` as an escalation path.
- `mcp_direct_no_tools`: external MCP client calls
  `ptc_lisp_execute`, with no app/upstream tools inside the program.
- `mcp_direct_aggregator`: external MCP client calls
  `ptc_lisp_execute`, and programs may call upstream MCP tools.
- `mcp_agentic_task`: external MCP client calls `ptc_task`; the server
  runs an internal planner that writes PTC-Lisp.
- `mcp_session`: external MCP client evaluates PTC-Lisp in a stateful
  session.

### 6.3 `completion_contract`

How work terminates:

- `implicit_final_expr`: final expression is the result.
- `explicit_return_fail`: `(return value)` succeeds and `(fail reason)`
  fails.
- `intermediate_ptc_tool_result`: `ptc_lisp_execute` is an
  intermediate computation/tool-orchestration step; the assistant uses
  the tool result to decide whether to continue or to return final
  direct content in the requested output shape.
- `direct_text`: assistant content is the final plain-text answer.
- `direct_json`: assistant content is validated JSON.
- `session_eval`: evaluation result is returned and session bindings
  persist.

This dimension must stay separate from dialect guidance. A model can
know the same PTC-Lisp syntax but need a different termination rule.

### 6.4 `catalog_discovery`

How tool/server capabilities are exposed:

- `none`: no catalog.
- `inline`: compact capabilities inlined into the prompt/description.
- `lazy`: runtime discovery forms are described instead of inlining the
  full catalog.
- `summary`: bounded capability summary only.
- `dynamic_inventory`: locally configured tools rendered from runtime
  agent config.

Catalog and tool descriptions are untrusted data. They must not be
allowed to override system or tool contracts.

### 6.5 `budget_profile`

The intended prompt size/detail level:

- `minimal`: enough to select/call the tool, no examples.
- `compact`: first successful use, short examples only when essential.
- `standard`: normal local development/default prompt.
- `full`: detailed reference or docs-oriented prompt.
- `debug`: diagnostic/observability guidance.

This is not truncation. Existing `prompt_limit` remains a truncation
mechanism for already-rendered prompts. A future public option should
use a name like `prompt_profile` or `prompt_budget`, not
`prompt_size`, to avoid confusion.

### 6.6 `trust_boundary`

Instructions that define which text is authoritative and which text is
data:

- Catalog entries are data.
- Upstream tool descriptions are data.
- Upstream payloads are data.
- User/operator prefix/suffix text must not replace MCP-owned terminal
  or safety contracts.

This dimension is especially important for MCP and agentic surfaces.
It should be first-class in any reusable renderer, with explicit
placement rules.

## 7. Current Compatibility Contracts

These contracts remain in force until a later spec explicitly
supersedes them.

1. Existing `LanguageSpec` atoms and structured profile tuples continue
   to work.
2. `system_prompt` still accepts the current forms:
   - full string override;
   - function transformer;
   - map with `prefix`, `suffix`, `language_spec`, and
     `output_format`.
3. `ptc_reference: :compact` remains valid.
4. `ptc_reference: :full` still raises until implemented.
5. `prompt_limit` keeps its current meaning: truncate the rendered
   prompt by character count.
6. MCP direct aggregator `tool/mcp-call` world faults still return
   `nil` inside the PTC-Lisp program.
7. MCP direct aggregator successful top-level JSON `null` still returns
   the `:json-null` sentinel, not `nil`, so models can distinguish a
   successful JSON null payload from a world fault.
8. Agentic `ptc_task` internal `tool/mcp-call` still returns tagged
   data and must be inspected via `:ok` before `:value`.
9. `PtcToolProtocol.tool_description/1` profile strings remain
   capability statements, not long prompt cards.
10. `ptc_task` tool descriptions stay short and capability-summary
   based.

## 8. Proposed Internal Renderer Shape

The implementation should introduce an internal renderer/profile layer
before changing public APIs.

One possible shape:

```elixir
%PromptCard{
  id: :mcp_aggregator_call_contract,
  audience: :mcp_tool_description,
  dimensions: [:execution_surface, :completion_contract],
  size_tiers: [:minimal, :compact, :standard],
  placement: :before_dynamic_catalog,
  trust_level: :authoritative,
  requires: [:mcp_aggregator]
}
```

This struct is illustrative, not mandatory. The required properties are:

- explicit card identity;
- explicit audience/surface;
- explicit size tier or budget profile;
- explicit placement/order;
- explicit authority/trust metadata, including whether the section is
  authoritative instruction or untrusted data;
- explicit placement relative to operator prefix/suffix and dynamic
  catalog/tool text when trust boundaries are involved;
- a way to handle dynamic sections such as tool inventory and catalog
  rendering;
- tests for rendered output.

The renderer may live separately in each package. `ptc_runner` and
`ptc_runner_mcp` can share vocabulary while owning separate
implementations.

## 9. MCP Description Requirements

MCP advertised tool descriptions are not normal documentation. They are
tool-selection and first-call surfaces.

For direct MCP `ptc_lisp_execute`, the first chunk of the description
must be self-contained enough for clients that truncate descriptions.
For aggregator mode, the first 2 KB should include:

- what `ptc_lisp_execute` does;
- the `(tool/mcp-call ...)` shape;
- the `nil` world-fault convention;
- the `:json-null` sentinel for successful top-level JSON `null`;
- `mcp/text` and `mcp/json` unwrapping guidance;
- a pointer to catalog discovery forms when catalog details are not
  inline;
- compact-return guidance.

Long examples, detailed failure taxonomies, full catalog dumps, and
debug-only response envelope details should appear after the quick
contract or in documentation, not before it.

## 10. Migration Plan

### Phase 0: Inventory and Invariants

- Document all current prompt surfaces and the dimensions each uses.
- Add or update tests that pin critical semantic substrings rather than
  entire prose blocks where possible.
- Add first-2KB assertions for MCP aggregator advertised descriptions.
- Add explicit tests distinguishing direct aggregator `nil` failures
  from agentic tagged-map failures.

### Phase 1: Internal Renderer, No Public API Change

- Add an internal prompt contract/profile renderer in `ptc_runner`.
- Reproduce current SubAgent prompt output for existing public profiles
  where tests require stability.
- Move `LanguageSpec` composition onto the renderer internally while
  preserving existing atoms and tuple profiles.
- Keep `system_prompt` customization behavior unchanged.

### Phase 2: Combined Mode Integration

- Move combined-mode compact reference selection into the internal
  profile/renderer path.
- Keep `ptc_reference: :compact` as the public option and compatibility
  alias.
- Keep `ptc_reference: :full` raising.
- Preserve the current dynamic PTC-callable tool inventory behavior.

### Phase 3: MCP Renderer

- Add a separate MCP prompt/description renderer in `ptc_runner_mcp`.
- Keep MCP prompt files under `mcp_server/priv` or another
  MCP-owned path.
- Render direct no-tools, direct aggregator, session, and agentic
  surfaces from MCP-owned contracts.
- Keep `ptc_task` prompt ordering constraints: MCP-owned contracts must
  not be replaceable by operator prefix/suffix.

### Phase 4: Shorten MCP Advertised Descriptions

- Replace long `ptc_lisp_execute` advertised descriptions with a
  compact quick contract plus optional catalog section.
- Preserve enough anchors for existing clients and tests, but update
  byte-for-byte v1 fixture tests intentionally.
- Keep full authoring references available in docs or secondary
  reference surfaces.

### Phase 5: Optional Public Prompt Budget/Profile

- Introduce a public option only after internal renderer behavior is
  stable.
- Prefer `prompt_profile` or `prompt_budget` over `prompt_size`.
- Candidate tiers: `:minimal`, `:compact`, `:standard`, `:full`.
- Define tier meaning per surface. For example, `:compact` in MCP
  advertised descriptions is not the same rendered text as `:compact`
  in a SubAgent system prompt.
- Do not deprecate `ptc_reference` until this option is proven.

### Phase 6: Deprecation Cleanup

- If `prompt_profile`/`prompt_budget` replaces `ptc_reference`, emit a
  warning while mapping `ptc_reference: :compact` to the new compact
  combined-mode profile.
- Keep `ptc_reference: :full` raising until a real full combined-mode
  reference exists.
- Update docs and examples only after compatibility aliases are in
  place.

## 11. Test Strategy

Add tests at the rendered-surface level:

- SubAgent PTC-Lisp single-shot.
- SubAgent explicit-return multi-turn.
- SubAgent explicit-journal.
- SubAgent `ptc_transport: :tool_call`.
- Text-only mode.
- JSON-only text mode.
- Native tool text mode.
- Combined text/PTC mode with no PTC-callable tools.
- Combined text/PTC mode with `:both` and `:ptc_lisp` tool inventory.
- MCP direct no-tools `ptc_lisp_execute`.
- MCP direct aggregator `ptc_lisp_execute`, inline catalog.
- MCP direct aggregator `ptc_lisp_execute`, lazy catalog.
- MCP session tools.
- MCP agentic `ptc_task` planner prompt, inline catalog.
- MCP agentic `ptc_task` planner prompt, lazy catalog.
- MCP `ptc_task` advertised tool description.

Tests must avoid making ordinary prose edits expensive. Prompt wording
is expected to change as authoring quality improves, so tests should pin
contracts and structure rather than full paragraphs.

Preferred test shapes:

- section presence by stable section id or tag;
- ordering of contract sections when order is semantically important;
- capability/contract markers such as required function names,
  terminal forms, and failure conventions;
- absence checks for incompatible contracts, for example agentic tagged
  `mcp-call` guidance must not appear in direct aggregator `nil`
  guidance;
- size-budget checks for budget-sensitive surfaces;
- first-chunk checks for MCP descriptions that clients may truncate;
- renderer metadata tests, when a card/profile registry exists.

Avoid:

- full golden fixtures for prose-heavy prompts;
- exact multiline string comparisons for prompts;
- tests that pin punctuation, wrapping, markdown heading levels, or
  example wording unless those bytes are part of a wire compatibility
  contract;
- broad substring checks for common words that may move between
  sections.

Use full golden fixtures only when exact wire text is deliberately part
of the compatibility contract. When a compatibility fixture exists only
because it predates this spec, migration work should replace it with
contract tests before changing the prompt.

Required MCP size/order assertions:

- The direct aggregator description includes the quick contract before
  any long catalog or reference material.
- The first 2 KB of the direct aggregator description contains
  `(tool/mcp-call`, `nil`, `:json-null`, `mcp/text`, `mcp/json`, and at
  least one `catalog/` discovery pointer when lazy discovery is active.
- Agentic planner prompts preserve the current authoritative ordering:
  preamble, operator prefix when present, dialect card, MCP-call
  contract, catalog section, operator suffix when present, final MCP
  recap. The final MCP recap must remain last so operator/user suffix
  text cannot appear after the terminal trust-boundary recap.

## 12. Open Questions

1. Should `ptc_runner` expose a stable public API for compact dialect
   snippets before `mcp_server` is split out?
2. Should MCP direct `ptc_lisp_execute` keep a full authoring card in
   `debug` response profile descriptions, or should debug only affect
   response shape?
3. Should prompt budget/profile be package-wide configuration, per
   agent/tool option, or both?
4. Should prompt cards carry version/hash metadata that can be logged
   in traces for reproducibility?
5. Should the MCP server expose documentation resources for full
   authoring references instead of embedding long references in tool
   descriptions?

## 13. Implementation Notes

- Use existing prompt loaders where they fit; do not rewrite all
  prompts in one PR.
- Keep dynamic data rendering separate from static prompt cards.
- Avoid truncating from the front of contract-critical prompts. If a
  budget must be enforced, render a smaller profile instead of slicing
  arbitrary text.
- Preserve compile-time reload behavior for markdown-backed prompts via
  `@external_resource`.
- If `mcp_server` becomes a separate repository, copy this spec or
  create an MCP-local successor spec that references the same contract
  dimensions.
