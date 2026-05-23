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
- Mention contextual namespaces and forms only in surfaces where they are usable:
  `tool/`, `data/`, `mcp/`, `budget/`, and REPL discovery forms.
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
<!-- used-by: Primary module or runtime component that loads the prompt -->
<!-- profiles: Runtime profiles or modes that include the prompt -->
<!-- shown-in: Runtime message/surface where the rendered text appears -->
<!-- composed-with: Other cards, templates, or dynamic text rendered nearby -->
<!-- mcp-tools: MCP tool names that include this card, when applicable -->
<!-- mcp-profiles: PromptRegistry profile keys that include this card -->
```

`date:` is the last prompt-content or metadata-policy update date, not the file
creation date. Metadata is not sent to the model. The budget applies to the
extracted prompt content between `PTC_PROMPT_START` and `PTC_PROMPT_END`.

Do not add `style:` metadata. This README defines the default style for all
prompts.

Maintained prompt files are:

- `priv/prompts/*.md`, excluding this README
- `mcp_server/priv/prompts/**/*.md`

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
is composed by `PtcRunnerMcp.PromptRegistry`. Each advertised MCP tool has a
file-backed prompt under `mcp_server/priv/prompts/tools/`. PTC-Lisp REPL
discovery guidance lives under `mcp_server/priv/prompts/discovery/` and is
rendered into upstream-enabled MCP descriptions or agentic planner prompts when
upstream discovery is available. Core `PtcRunner.PtcToolProtocol`
may keep legacy or in-process tool descriptions, but MCP `tools/list`
descriptions should not depend on core prompt strings.

## Naming

Files use kebab-case for root PTC-Lisp prompt cards. MCP prompt files use the
runtime names they describe: MCP tool prompt filenames match tool names under
`mcp_server/priv/prompts/tools/`, and discovery prompt filenames match the
discovery cards under `mcp_server/priv/prompts/discovery/`.

| Prefix | Category | Used By |
|--------|----------|---------|
| `behavior-` | PTC-Lisp behavior and return-mode fragments | `PtcRunner.Lisp.LanguageSpec` |
| `capability-` | Optional composable PTC-Lisp capabilities | `PtcRunner.Lisp.LanguageSpec` |
| `json-` | Text-mode JSON variant prompts | `PtcRunner.SubAgent.Loop.TextMode` |
| `tool-calling-` | Text-mode tool-calling system prompt | `PtcRunner.SubAgent.Loop.TextMode` |
| `turn-feedback-` | Retry/final-turn feedback | `PtcRunner.SubAgent.Loop.TurnFeedback` |
| `ptc_text_mode_` | Combined text + PTC-Lisp compact reference | `PtcRunner.SubAgent.SystemPrompt` |
| `mcp_server/priv/prompts/tools/` | MCP `tools/list` tool descriptions | `PtcRunnerMcp.PromptRegistry` |
| `mcp_server/priv/prompts/discovery/` | PTC-Lisp REPL discovery guidance for MCP upstream discovery | `PtcRunnerMcp.CatalogPrompt` |
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
| `mcp_server/priv/prompts/tools/lisp_eval.md` | `PtcRunnerMcp.PromptRegistry.render/2` | `PtcRunnerMcp.Tools` | `:mcp_no_tools` | Complete stateless one-shot tool description | none | blank line | MCP `tools/list` description |
| `mcp_server/priv/prompts/tools/lisp_eval.with_upstreams.md` | `PtcRunnerMcp.PromptRegistry.render/2` | `PtcRunnerMcp.Tools` | `:mcp_aggregator` | Complete stateless one-shot upstream-enabled description | optional upstream catalog text | blank line | MCP `tools/list` description |
| `mcp_server/priv/prompts/tools/lisp_session_*.md` | `PtcRunnerMcp.PromptRegistry.render/2` | `PtcRunnerMcp.Sessions` | `:mcp_session` | Per-session-tool description | upstream guidance only in `lisp_session_eval.with_upstreams.md` | blank line | MCP `tools/list` description |
| `mcp_server/priv/prompts/tools/lisp_task.md` | `PtcRunnerMcp.PromptRegistry.render/2` | `PtcRunnerMcp.Agentic` | `:mcp_agentic_task` | Agentic task tool description | optional capability summary appended in code | blank line | MCP `tools/list` description |
| `mcp_server/priv/prompts/tools/lisp_debug.md` | `PtcRunnerMcp.PromptRegistry.render/2` | `PtcRunnerMcp.DebugTool` | `:mcp_debug` | Debug tool description | none | blank line | MCP `tools/list` description |
| `mcp_server/priv/prompts/discovery/*.md` | `PtcRunnerMcp.CatalogPrompt` | `PtcRunnerMcp.CatalogDescription`, `PtcRunnerMcp.PromptRegistry` | upstream-enabled MCP descriptions and agentic lazy discovery prompt | REPL discovery guidance cards | configured server/tool catalog data elsewhere | newline | MCP description or agentic prompt |
| agentic planner cards | in-code functions in `PtcRunnerMcp.PromptRegistry` | agentic planner | `:mcp_agentic_task` | Profile-specific planner prompt cards | optional operator text or catalog | blank line | agentic system prompt |
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

1. Create the prompt file with metadata and prompt markers in the right prompt
   tree: root `priv/prompts/` for core PTC-Lisp prompts,
   `mcp_server/priv/prompts/tools/` for advertised MCP tools, or
   `mcp_server/priv/prompts/discovery/` for REPL discovery guidance.
2. For root PTC-Lisp prompts, add the file path, `@external_resource`, loaded
   content, and public function to `PtcRunner.Prompts`.
3. For MCP tool prompts, add the file to `PtcRunnerMcp.PromptRegistry` prompt
   specs and profile/card metadata.
4. For discovery prompt cards, add the file to `PtcRunnerMcp.CatalogPrompt`.
5. Add or update prompt registry metadata when the prompt is a card/profile
   member.
6. Update this README's tables and usage matrix.
