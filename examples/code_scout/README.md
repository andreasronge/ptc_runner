# Code Scout Example

Code Scout is a mini-library and Mix task that demonstrates how to use `ptc_runner` SubAgents to investigate a codebase.

It uses an LLM-driven agent that has access to `grep` and `read_file` tools to navigate your source code and answer questions.

## Concepts Demonstrated

This example showcases several key `ptc_runner` features:

### 1. Automatic Type Signature Extraction

Tools use Elixir `@spec` annotations that are automatically converted to PTC-Lisp signatures:

```elixir
# In tools.ex
@spec grep(%{pattern: String.t()}) :: [%{file: String.t(), line: integer(), snippet: String.t()}]
def grep(%{pattern: pattern}) do ...

# Extracted signature: (map {pattern :string}) -> [{file :string, line :int, snippet :string}]
```

### 2. Function References as Tools

Instead of anonymous wrapper functions, use direct function references:

```elixir
tools: %{
  "grep" => &Tools.grep/1,        # Signature and @doc auto-extracted
  "read_file" => &Tools.read_file/1
}
```

### 3. Multi-turn Agent Loop

The agent can make multiple tool calls across turns to investigate iteratively:

```elixir
max_turns: 10
```

### 4. Return Type Validation

The agent must return data matching its signature. Invalid returns trigger automatic feedback:

```elixir
signature: "(query :string) -> {answer :string, relevant_files [:string], confidence :float}"
```

### 5. Template Variables in Prompts

Context values are interpolated into prompts using `{{variable}}` syntax:

```elixir
prompt: "Your task is to answer the user's query: \"{{query}}\""
# ...
context = %{"query" => query_string}
```

### 6. Custom LLM Integration

Shows how to wire up any LLM provider:

```elixir
llm_fn = fn input ->
  messages = [%{role: :system, content: input.system} | input.messages]
  case LLMClient.generate_text(model, messages) do
    {:ok, response} -> {:ok, %{content: response.content, tokens: response.tokens}}
    {:error, reason} -> {:error, reason}
  end
end
SubAgent.run(agent, llm: llm_fn)
```

### 7. Tracing

Inspect agent behavior with `--trace` (add `--verbose` for full messages), or view the system prompt with `--system-prompt`.

## Prerequisite

You must have an LLM configured. By default, this example uses `llm_client` (local sibling project) and will attempt to load a `.env` file from the project root (containing e.g., `OPENROUTER_API_KEY`).

## Installation

1. Navigate to this directory:
   ```bash
   cd examples/code_scout
   ```
2. Get dependencies:
   ```bash
   mix deps.get
   ```

## Usage

You can run the Code Scout via the Mix task:

```bash
mix code.scout "Where is the Lisp evaluator implemented and what are its main functions?"
```

### Max Turns

By default, the agent runs for up to 10 turns. Use `--max-turns` (or `-m`) to change this:

```bash
mix code.scout "How does the sandbox work?" --max-turns 3
```

### Tracing

To see the agent's multi-turn reasoning and tool calls, use the `--trace` flag:

```bash
mix code.scout "How are PTC-Lisp special forms handled?" --trace
```

Add `--verbose` (or `-v`) to include full LLM messages:

```bash
mix code.scout "Find the evaluator" --trace --verbose
```

Add `--raw` (or `-r`) to see the raw LLM response including thinking/reasoning before the program:

```bash
mix code.scout "Find the evaluator" --trace --raw
```

### Compression

For multi-turn agents, use `--compression` (or `-c`) to coalesce message history into a compact format. This reduces token usage but may affect error recovery in complex queries:

```bash
mix code.scout "How does the sandbox work?" --compression
```

See [Message Compression](../../docs/guides/subagent-compression.md) for details on how compression works.

### Inspecting the System Prompt

To see the full system prompt that would be sent to the LLM (without running the agent):

```bash
mix code.scout "Where is eval?" --system-prompt
```

## Project Structure

- `lib/code_scout.ex`: Public API and LLM integration.
- `lib/code_scout/agent.ex`: SubAgent definition with signature and tools.
- `lib/code_scout/tools.ex`: Tool implementations with `@spec` for auto-extraction.
- `lib/mix/tasks/code.scout.ex`: CLI with tracing and debug options.
