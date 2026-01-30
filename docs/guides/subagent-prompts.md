# Prompt Customization

This guide covers customizing SubAgent system prompts for different LLMs, execution modes, and use cases.

## System Prompt Structure

SubAgent generates a system prompt with these sections:

1. **Role & Purpose** - Defines agent as PTC-Lisp generator
2. **Rules** - Boundaries for code generation
3. **Data Inventory** - Typed view of `data/` variables
4. **Tool Schemas** - Available tools with signatures
5. **Language Reference** - PTC-Lisp syntax (customizable)
6. **Output Format** - Code block requirements (customizable)
7. **Mission** - User's task from `prompt` option

## Customization Options

The `system_prompt` field accepts three forms:

```elixir
# Map with options
system_prompt: %{
  prefix: "You are an expert data analyst.",
  suffix: "Always validate results before returning.",
  language_spec: :multi_turn,
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
| `:language_spec` | Replaces PTC-Lisp reference section |
| `:output_format` | Replaces output format instructions |

## Language Spec Profiles

The `:language_spec` option controls the PTC-Lisp reference shown to the LLM:

| Profile | Description | Use Case |
|---------|-------------|----------|
| `:single_shot` | Base language reference | Quick lookups, no memory |
| `:multi_turn` | Base + memory addon | Conversational analysis |

```elixir
# Single-turn: no memory docs needed
SubAgent.new(
  prompt: "Count items over $100",
  max_turns: 1,
  system_prompt: %{language_spec: :single_shot}
)

# Multi-turn: include memory documentation
SubAgent.new(
  prompt: "Analyze sales trends",
  max_turns: 5,
  system_prompt: %{language_spec: :multi_turn}
)
```

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
        PtcRunner.Lisp.LanguageSpec.get(:multi_turn)
      end
    end
  }
)
```

The callback receives:

| Key | Type | Description |
|-----|------|-------------|
| `:turn` | integer | Current turn number (1-indexed) |
| `:model` | atom or function | The LLM (atom resolved via `llm_registry`, or callback function) |
| `:memory` | map | Current memory state |
| `:messages` | list | Conversation history |

## LLM-Specific Prompts

Different models may need different prompt styles:

```elixir
defmodule MyApp.Prompts do
  def language_spec_for_model(ctx) do
    base = PtcRunner.Lisp.LanguageSpec.get(:single_shot)

    case ctx.model do
      :gemini ->
        # Gemini benefits from more examples
        base <> "\n\n" <> extra_examples()

      :claude ->
        # Claude handles concise prompts well
        base

      _ ->
        base
    end
  end

  defp extra_examples do
    """
    ## Additional Examples

    ```clojure
    ;; Filtering with multiple conditions
    (->> data/orders
         (filter (all-of (where :status = "pending")
                         (where :total > 100)))
         (count))
    ```
    """
  end
end

# Usage
SubAgent.new(
  prompt: "Analyze orders",
  system_prompt: %{language_spec: &MyApp.Prompts.language_spec_for_model/1}
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

## Single-Turn vs Multi-Turn

The `:multi_turn` profile adds documentation for:
- `return`/`fail` for finishing the agentic loop and returning values to caller
- `println` for outputting values to LLM context (expression results are NOT shown)
- State persistence with `def` and `*1/*2/*3` for previous results

See [Language Spec Profiles](#language-spec-profiles) for examples.

## Prompt Preview

Inspect the generated prompt without execution:

```elixir
agent = SubAgent.new(
  prompt: "Find emails for {{user}}",
  system_prompt: %{
    prefix: "You are a helpful assistant.",
    language_spec: :multi_turn
  }
)

preview = SubAgent.preview_prompt(agent, context: %{user: "alice"})

IO.puts(preview.system)  # Full system prompt
IO.puts(preview.user)    # Expanded user prompt
```

## JSON Mode Templating

JSON mode uses full Mustache templating with sections for iterating lists. This differs from PTC-Lisp mode where data appears in the Data Inventory section.

See [JSON Mode Guide](subagent-json-mode.md) for Mustache syntax including `{{#section}}`, `{{^inverted}}`, and `{{.}}` notation.

## See Also

- [JSON Mode Guide](subagent-json-mode.md) - Mustache templates and structured output
- [Core Concepts](subagent-concepts.md) - Context, memory, and firewalls
- [Advanced Topics](subagent-advanced.md) - System prompt structure details
- `PtcRunner.SubAgent.SystemPrompt.generate/2` - API reference for prompt generation
- `PtcRunner.Lisp.LanguageSpec.get/1` - Available language spec profiles
