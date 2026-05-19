# Prompt Templates

Prompt templates in this directory are loaded at compile time by
`PtcRunner.Prompts`. Changes to these `.md` files trigger recompilation through
`@external_resource`.

MCP server prompt cards live under `mcp_server/priv/prompts/` and are registered
by `PtcRunnerMcp.PromptRegistry`.

## Prompt Authoring

Prompts are operational cards, not conformance docs.

- Default style is terse: drop filler, keep exact technical terms, allow
  fragments.
- Prefer `thing - facts` over explanatory paragraphs.
- Start short. Extend only after a real model failure, new runtime surface, or
  repeated review finding.
- Examples should prevent common mistakes, not exhaustively document the
  language.
- Complete compatibility detail belongs in generated docs and tests, not prompt
  cards.
- Runtime prompt content must be self-contained. Do not put authoring links,
  repo-doc references, or "see docs" instructions inside extracted prompt
  content.
- Mention contextual namespaces only in surfaces where they are usable: `tool/`,
  `data/`, `catalog/`, and `budget/`.
- Keep MCP helper examples out of non-MCP prompt surfaces.
- Do not claim general Java interop. List only the supported compatibility
  shape.

## File Format

Every maintained prompt file has maintainer-facing metadata before
`PTC_PROMPT_START`:

```markdown
<!-- version: 1 -->
<!-- date: YYYY-MM-DD -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: audience-name -->
<!-- budget: target<=N bytes, hard<=M bytes -->
```

Optional fields:

```markdown
<!-- changes: Short maintainer-facing change note -->
<!-- priority: Critical facts that must appear early -->
<!-- variables: comma-separated template variables -->
```

`date:` is the last prompt-content or metadata-policy update date, not the file
creation date. Metadata is not sent to the model. The budget applies to the
extracted prompt content between `PTC_PROMPT_START` and `PTC_PROMPT_END`.

Do not add `style:` metadata. This README defines the default style for all
prompts.

Maintained prompt files are:

- `priv/prompts/*.md`, excluding this README
- `mcp_server/priv/prompts/*.md`

Generated prompt files and non-prompt docs/examples are out of scope unless they
are explicitly added to that list later.

## Budgets

- MCP `tools/list` descriptions: target <= 1000 bytes, hard <= 2000 bytes.
- MCP description priority: purpose, call shape, result shape, failure
  convention first.
- Compact non-MCP cards: target <= 1000 bytes, hard <= 1500 bytes unless the
  file metadata says otherwise.
- Full reference prompts may be longer, but should still avoid exhaustive lists
  when generated docs and tests are the conformance source.

The 2000-byte hard cap for MCP `tools/list` descriptions is an external client
constraint. Keep the first 800 to 1000 bytes useful on their own.

## MCP Prompt Ownership

MCP-specific tool-description text lives under `mcp_server/priv/prompts/` and
is composed by `PtcRunnerMcp.PromptRegistry`. Keep MCP capability summaries,
surface-specific authoring cards, and session/aggregator cards there. Core
`PtcRunner.PtcToolProtocol` may keep legacy or in-process tool descriptions,
but MCP `tools/list` descriptions should not depend on core prompt strings.

## Naming

Files use kebab-case, except the compact combined-mode card and MCP server
`mcp_` files keep their historic underscore names.

| Prefix | Category | Used By |
|--------|----------|---------|
| `behavior-` | PTC-Lisp behavior and return-mode fragments | `PtcRunner.Lisp.LanguageSpec` |
| `capability-` | Optional composable PTC-Lisp capabilities | `PtcRunner.Lisp.LanguageSpec` |
| `json-` | Text-mode JSON variant prompts | `PtcRunner.SubAgent.Loop.TextMode` |
| `tool-calling-` | Text-mode tool-calling system prompt | `PtcRunner.SubAgent.Loop.TextMode` |
| `turn-feedback-` | Retry/final-turn feedback | `PtcRunner.SubAgent.Loop.TurnFeedback` |
| `ptc_text_mode_` | Combined text + PTC-Lisp compact reference | `PtcRunner.SubAgent.SystemPrompt` |
| none | Shared PTC-Lisp reference | `PtcRunner.Lisp.LanguageSpec` |

## Prompt Usage Matrix

Not every runtime prompt is file-only. Some surfaces compose file-backed cards,
in-code cards, and dynamic additions such as app-tool inventory or upstream MCP
catalog text. Review rendered surfaces, not only individual files, when changing
prompt wording, composition, or budgets.

| File or card | Loader | Used by | Profiles | Order | Dynamic additions | Joiner | Runtime surface |
|--------------|--------|---------|----------|-------|-------------------|--------|-----------------|
| `reference.md` | `PtcRunner.Prompts.reference/0` | `PtcRunner.Lisp.LanguageSpec` | `:single_shot`, `:explicit_return`, `:explicit_journal` | Reference card before behavior cards | none | blank line in composed spec | PTC-Lisp system prompt |
| `behavior-single-shot.md` | `PtcRunner.Prompts.behavior_single_shot/0` | `PtcRunner.Lisp.LanguageSpec` | `:single_shot` | After `reference.md` | none | blank line | PTC-Lisp system prompt |
| `behavior-multi-turn.md` | `PtcRunner.Prompts.behavior_multi_turn/0` | `PtcRunner.Lisp.LanguageSpec` | `:explicit_return`, `:explicit_journal` | After `reference.md` | mission log/context sections elsewhere | blank line | PTC-Lisp system prompt |
| `behavior-return-explicit.md` | `PtcRunner.Prompts.behavior_return_explicit/0` | `PtcRunner.Lisp.LanguageSpec` | `:explicit_return`, `:explicit_journal` | After multi-turn core | none | blank line | PTC-Lisp system prompt |
| `capability-journal.md` | `PtcRunner.Prompts.capability_journal/0` | `PtcRunner.Lisp.LanguageSpec` | `:explicit_journal` | After return-mode rules | mission log/progress runtime data | blank line | PTC-Lisp system prompt |
| `json-system.md` | `PtcRunner.Prompts.json_system/0` | `PtcRunner.SubAgent.Loop.TextMode` | JSON text mode | System prompt | custom system override can replace | none | provider system message |
| `json-user.md` | `PtcRunner.Prompts.json_user/0` | `PtcRunner.SubAgent.Loop.TextMode` | JSON text mode | User message template | task, output instruction, field descriptions | template render | provider user message |
| `json-error.md` | `PtcRunner.Prompts.json_error/0` | `PtcRunner.SubAgent.Loop.TextMode` | JSON text mode retry | Error feedback | validation error and invalid response | template render | provider user message |
| `tool-calling-system.md` | `PtcRunner.Prompts.tool_calling_system/0` | `PtcRunner.SubAgent.Loop.TextMode` | Tool-calling text mode | System prompt | output instruction appended in code | newline | provider system message |
| `turn-feedback-must-return.md` | `PtcRunner.Prompts.must_return_warning/0` | `PtcRunner.SubAgent.Loop.TurnFeedback` | Explicit-return final work turn | Inserted before final work turn | retry counts | template render | provider user feedback |
| `turn-feedback-retry.md` | `PtcRunner.Prompts.retry_feedback/0` | `PtcRunner.SubAgent.Loop.TurnFeedback` | Explicit-return retry turns | Inserted during retry phase | retry counters | template render | provider user feedback |
| `ptc_text_mode_compact_reference.md` | `PtcRunner.Prompts.ptc_text_mode_compact_reference/0` | `PtcRunner.SubAgent.SystemPrompt` | Combined text + PTC-Lisp | Appended to system prompt when compact reference is enabled | app-tool inventory appended outside the file | blank line / inventory section | provider system message |
| `mcp_no_tools_description.md` | `PtcRunnerMcp.PromptRegistry.card_text/1` | `PtcRunnerMcp.Tools` | `:mcp_no_tools` | Capability description before authoring card | none | blank line in composed description | MCP `tools/list` description |
| `mcp_no_tools_description` | `PtcRunnerMcp.PromptRegistry.render/2` | `PtcRunnerMcp.Tools` | `:mcp_no_tools` | no-tools description file, then authoring card | none | blank line | MCP `tools/list` description |
| `mcp_aggregator_description` | `PtcRunnerMcp.PromptRegistry.render/2` | `PtcRunnerMcp.Tools` | `:mcp_aggregator` | quick contract, file card, optional catalog | optional upstream catalog text | blank line | MCP `tools/list` description |
| `mcp_session_start_description` | `PtcRunnerMcp.PromptRegistry.render/2` | `PtcRunnerMcp.Tools` | `:mcp_session` | session file card, start detail | none | blank line | MCP `tools/list` description |
| `mcp_session_eval_description` | `PtcRunnerMcp.PromptRegistry.render/2` | `PtcRunnerMcp.Tools` | `:mcp_session` | session file card, eval detail | optional schema/signature args at call time | blank line | MCP `tools/list` description |
| hardcoded MCP detail/quick-contract cards | in-code functions in `PtcRunnerMcp.PromptRegistry` | `PtcRunnerMcp.Tools`, agentic planner | MCP direct/session/agentic profiles | Profile-specific | optional operator text or catalog | blank line | MCP descriptions and agentic system prompts |
| optional dynamic upstream catalog text | runtime catalog renderers | `PtcRunnerMcp.PromptRegistry` | aggregator and agentic MCP profiles | After authoritative cards | upstream server/tool inventory | blank line | MCP description or agentic prompt |

## Prompt Test Guidance

Prompt tests should protect contracts, composition, extraction, and budgets
without freezing ordinary prose.

- Prefer checks for markers/metadata exclusion, profile order, joiners, dynamic
  insertion points, required protocol forms, forbidden guidance, and byte
  budgets.
- Avoid full-prompt snapshots, byte-for-byte prompt equality, broad substring
  checks for editorial wording, and example/heading assertions unless the text
  is a documented runtime contract.
- For MCP descriptions, assert schema shape, key operational facts, absence of
  metadata/markers, and byte limits rather than full fixture equality.

## Adding a Prompt

1. Create `priv/prompts/category-name.md` with metadata and prompt markers.
2. Add the file path, `@external_resource`, loaded content, and public function
   to `PtcRunner.Prompts`.
3. Add or update `PtcRunner.Lisp.PromptRegistry` metadata when the prompt is a
   PTC-Lisp card/profile member.
4. Update this README's tables and usage matrix.
