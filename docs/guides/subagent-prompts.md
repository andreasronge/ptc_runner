# Prompt Customization

This guide covers customizing SubAgent system prompts for different LLMs, execution modes, and use cases.

## Execution Modes

SubAgent prompts are built from a 2-axis architecture:

**Behavior axis** — how the agent returns results:

| Behavior | Description | When to use |
|----------|-------------|-------------|
| `:single_shot` | Last expression IS the answer | `max_turns: 1`, simple queries |
| `:explicit_return` | Must call `(return ...)` or `(fail ...)` | Multi-turn exploration with tools |
| `:auto_return` | `println` = continue, no `println` = answer | When you want simpler completion semantics |

**Reference** — optional language documentation (tool syntax, Java interop, restrictions):

The language reference is **not** included by default. Add it with `reference: :full` for weaker models that need syntax guidance.

**Additive capabilities:**

| Capability | Description | When to use |
|------------|-------------|-------------|
| `:journal` | Adds `task`, `step-done`, `task-reset` docs | Plan-driven agents with idempotent steps |

### Default Selection

SubAgent automatically selects a prompt based on configuration:

| Condition | Default Language Spec |
|-----------|----------------------|
| `max_turns <= 1` | `:single_shot` |
| `completion_mode: :auto` + plan | `:explicit_journal` |
| `completion_mode: :auto` | `:auto_return` |
| `journaling: true` | `:explicit_journal` |
| Otherwise | `:explicit_return` |

You rarely need to set this manually — the defaults match the runtime behavior.

## Canonical Language Specs

Pre-composed specs available via `system_prompt: %{language_spec: atom}`:

| Spec | Components | Description |
|------|------------|-------------|
| `:single_shot` | reference + single-shot | Last expr = answer, one turn |
| `:explicit_return` | reference + multi-turn + explicit return | Must call `(return ...)`/`(fail ...)` |
| `:auto_return` | reference + multi-turn + auto return | println = continue, no println = answer |
| `:explicit_journal` | multi-turn + explicit return + journal | With task caching |
| `:repl` | Standalone REPL prompt | One expression per turn |

The language reference is not included by default. Use `reference: :full` in a structured profile to add it.

```elixir
# Single-turn query (default for max_turns: 1)
SubAgent.new(
  prompt: "Count items over $100",
  max_turns: 1
)

# Multi-turn exploration (default for max_turns > 1)
SubAgent.new(
  prompt: "Analyze sales trends",
  max_turns: 5
)

# Explicit override: use auto-return mode
SubAgent.new(
  prompt: "Explore the data",
  max_turns: 5,
  completion_mode: :auto,
  system_prompt: %{language_spec: :auto_return}
)

# Add language reference for weaker models
SubAgent.new(
  prompt: "Count items",
  max_turns: 1,
  system_prompt: %{language_spec: {:profile, :single_shot, reference: :full}}
)
```

## Structured Profiles

For programmatic composition, use the `{:profile, behavior, opts}` tuple:

```elixir
# Add language reference for a weaker model
SubAgent.new(
  prompt: "Execute the plan",
  system_prompt: %{
    language_spec: {:profile, :explicit_return, reference: :full}
  }
)

# Add journal capability
SubAgent.new(
  prompt: "Execute the plan",
  system_prompt: %{
    language_spec: {:profile, :explicit_return, journal: true}
  }
)

# Both reference and journal
system_prompt: %{language_spec: {:profile, :explicit_return, reference: :full, journal: true}}

# Short form (defaults: reference: :none, journal: false)
system_prompt: %{language_spec: {:profile, :explicit_return}}
```

**Options:**

| Option | Values | Default |
|--------|--------|---------|
| `:reference` | `:none` or `:full` | `:none` |
| `:journal` | `true` or `false` | `false` |

**Validation:** Raises `ArgumentError` for invalid combinations (e.g., `single_shot + journal`).

## System Prompt Customization

The `system_prompt` field accepts three forms:

```elixir
# Map with options
system_prompt: %{
  prefix: "You are an expert data analyst.",
  suffix: "Always validate results before returning.",
  language_spec: :explicit_return,
  output_format: "..."
}

# Function transformer
system_prompt: fn prompt -> "CUSTOM PREFIX\n\n" <> prompt end

# Complete override (use with caution)
system_prompt: "Your entire custom prompt here..."
```

### Map Options

| Option | Description |
|--------|-------------|
| `:prefix` | Prepended before generated content |
| `:suffix` | Appended after generated content |
| `:language_spec` | Replaces PTC-Lisp reference section (atom, string, tuple, or callback) |
| `:output_format` | Replaces output format instructions |

## Dynamic Language Spec

Use a callback to change prompts based on runtime context:

```elixir
SubAgent.new(
  prompt: "Process the data",
  system_prompt: %{
    language_spec: fn ctx ->
      if ctx.turn == 1 do
        PtcRunner.Lisp.LanguageSpec.get(:single_shot)
      else
        PtcRunner.Lisp.LanguageSpec.get(:explicit_return)
      end
    end
  }
)
```

The callback receives:

| Key | Type | Description |
|-----|------|-------------|
| `:turn` | integer | Current turn number (1-indexed) |
| `:model` | atom or function | The LLM |
| `:memory` | map | Current memory state |
| `:messages` | list | Conversation history |

## LLM-Specific Prompts

Different models may need different prompt styles. Benchmark results show weaker models benefit from the language reference while capable models work fine without it:

```elixir
defmodule MyApp.Prompts do
  alias PtcRunner.Lisp.LanguageSpec

  def for_model(ctx) do
    case ctx.model do
      model when model in [:haiku, :gemini] ->
        # Weaker models: add language reference
        LanguageSpec.resolve_profile({:profile, :explicit_return, reference: :full})

      _ ->
        # Capable models: default (no reference)
        LanguageSpec.get(:explicit_return)
    end
  end
end

SubAgent.new(
  prompt: "Analyze orders",
  system_prompt: %{language_spec: &MyApp.Prompts.for_model/1}
)
```

## Custom Prompt Addons

Build on top of library prompts:

```elixir
defmodule MyApp.Prompts do
  alias PtcRunner.Lisp.LanguageSpec

  def with_domain_context do
    """
    #{LanguageSpec.get(:single_shot)}

    ## Domain Context

    - Orders have statuses: pending, shipped, delivered, cancelled
    - Products belong to categories: electronics, clothing, food
    - Use `data/current_user` for permission checks
    """
  end
end

SubAgent.new(
  prompt: "Find high-value orders",
  system_prompt: %{language_spec: MyApp.Prompts.with_domain_context()}
)
```

## Prompt Preview

Inspect the generated prompt without execution:

```elixir
agent = SubAgent.new(
  prompt: "Find emails for {{user}}",
  system_prompt: %{
    prefix: "You are a helpful assistant.",
    language_spec: :explicit_return
  }
)

preview = SubAgent.preview_prompt(agent, context: %{user: "alice"})

IO.puts(preview.system)  # Full system prompt
IO.puts(preview.user)    # Expanded user prompt
```

## Text Mode Templating

Text mode uses full Mustache templating with sections for iterating lists. This differs from PTC-Lisp mode where data appears in the Data Inventory section.

See [Text Mode Guide](subagent-text-mode.md) for Mustache syntax including `{{#section}}`, `{{^inverted}}`, and `{{.}}` notation.

## See Also

- [Text Mode Guide](subagent-text-mode.md) - Mustache templates, structured output, and native tool calling
- [Core Concepts](subagent-concepts.md) - Context, memory, and firewalls
- [Advanced Topics](subagent-advanced.md) - System prompt structure details
- [Benchmark Analysis](benchmark-analysis.md) - Statistical testing of prompt variants
- `PtcRunner.Lisp.LanguageSpec` - Full API reference for language specs and profiles
- `PtcRunner.SubAgent.SystemPrompt` - Prompt generation internals
