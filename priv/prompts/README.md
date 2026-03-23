# Prompt Templates

All prompt templates live in this directory and are loaded at compile time by `PtcRunner.Prompts`.
Changes to any `.md` file here trigger recompilation via `@external_resource`.

## Naming Convention

Files use **kebab-case** with a **category prefix** that groups related prompts:

| Prefix | Category | Used By |
|--------|----------|---------|
| `behavior-` | Execution mode (single-shot, multi-turn, return variants) | `LanguageSpec` |
| `capability-` | Optional composable capabilities | `LanguageSpec` |
| `json-` | JSON/text mode prompts (system, user, error) | `JsonMode` |
| `turn-feedback-` | Turn feedback (warnings, retry info) | `TurnFeedback` |
| `verification-predicate-` | Verification predicate guides | `MetaPlanner` |
| `tool-calling-` | Tool calling mode | `ToolCallingMode` |
| `lisp-addon-` | Standalone Lisp mode addons | `SubAgent` |
| *(none)* | Top-level shared prompts | Various |

Unprefixed files: `reference.md` (language reference), `planning-examples.md`, `signature-guide.md`.

## File → Function Mapping

The filename maps to a function in `PtcRunner.Prompts` by replacing hyphens with underscores
(with some short-form aliases):

| File | Function |
|------|----------|
| `reference.md` | `reference/0` |
| `behavior-single-shot.md` | `behavior_single_shot/0` |
| `behavior-multi-turn.md` | `behavior_multi_turn/0` |
| `behavior-return-explicit.md` | `behavior_return_explicit/0` |
| `behavior-return-auto.md` | `behavior_return_auto/0` |
| `capability-journal.md` | `capability_journal/0` |
| `lisp-addon-repl.md` | `repl/0` |
| `json-system.md` | `json_system/0` |
| `json-user.md` | `json_user/0` |
| `json-error.md` | `json_error/0` |
| `tool-calling-system.md` | `tool_calling_system/0` |
| `turn-feedback-must-return.md` | `must_return_warning/0` |
| `turn-feedback-retry.md` | `retry_feedback/0` |
| `planning-examples.md` | `planning_examples/0` |
| `verification-predicate-guide.md` | `verification_guide/0` |
| `verification-predicate-reminder.md` | `verification_reminder/0` |
| `signature-guide.md` | `signature_guide/0` |

## File Format

Prompt files use HTML comment markers to separate metadata from content:

```markdown
# Title
Description for maintainers.

<!-- PTC_PROMPT_START -->
Actual prompt content sent to the LLM.
<!-- PTC_PROMPT_END -->
```

Content between `PTC_PROMPT_START` and `PTC_PROMPT_END` is extracted by `PtcRunner.PromptLoader`.
If no markers exist, the entire file (trimmed) is used.

Some prompts use **Mustache templating** (`{{variable}}`, `{{#section}}...{{/section}}`).
See `PtcRunner.Mustache` for expansion.

## Adding a New Prompt

1. Create `priv/prompts/category-name.md` using kebab-case and an appropriate prefix
2. Add to `PtcRunner.Prompts`: file path, `@external_resource`, loaded content, and public function
3. Update the tables above and in `PtcRunner.Prompts` moduledoc
