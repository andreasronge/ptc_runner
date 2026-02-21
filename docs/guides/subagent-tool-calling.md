# Tool Calling Mode SubAgents

Tool calling mode uses provider-native tool calling APIs (OpenAI function_calling, Anthropic tool_use) instead of PTC-Lisp for tool invocation.

## When to Use Tool Calling Mode

Use tool calling mode when your LLM supports native tool calling but not PTC-Lisp generation:

| Task Type | Mode | Why |
|-----------|------|-----|
| Tools with small/fast LLMs | Tool Calling | Small models can't generate PTC-Lisp reliably |
| Tools with any LLM | PTC-Lisp | Full computation, memory, and orchestration |
| Structured output only | JSON | No tools needed |

**Choose tool calling over PTC-Lisp when:**
- Using smaller models (Haiku, GPT-4.1 Mini, Gemma, Llama) that struggle with PTC-Lisp syntax
- You want the LLM provider to handle tool schema formatting
- You don't need memory persistence between turns

## Basic Usage

```elixir
{:ok, step} = SubAgent.run(
  "What is 17 + 25? Use the add tool.",
  output: :tool_calling,
  signature: "() -> {result :int}",
  tools: %{
    "add" => {fn args -> args["a"] + args["b"] end,
              signature: "(a :int, b :int) -> :int",
              description: "Add two numbers"}
  },
  llm: my_llm
)

step.return["result"]  #=> 42
```

**Requirements:** Tool calling mode requires both a signature (for validating the final JSON answer) and at least one tool.

## How It Works

The execution flow differs from PTC-Lisp mode:

1. Tool signatures are converted to JSON Schema and sent to the LLM provider
2. The LLM uses its native tool calling API to request tool executions
3. ptc_runner executes the tools and feeds results back
4. The loop continues until the LLM returns a final JSON answer
5. The answer is validated against the agent's signature

```
LLM ──tool_call──> ptc_runner executes tool ──result──> LLM
LLM ──tool_call──> ptc_runner executes tool ──result──> LLM
LLM ──JSON answer──> validate against signature ──> Step
```

## Multiple Tools

Provide multiple tools and the LLM decides which to call:

```elixir
tools = %{
  "multiply" => {fn args -> args["a"] * args["b"] end,
                 signature: "(a :int, b :int) -> :int",
                 description: "Multiply two numbers"},
  "subtract" => {fn args -> args["a"] - args["b"] end,
                 signature: "(a :int, b :int) -> :int",
                 description: "Subtract b from a"}
}

{:ok, step} = SubAgent.run(
  "Calculate (6 * 7) - 10",
  output: :tool_calling,
  signature: "() -> {result :int}",
  tools: tools,
  max_turns: 5,
  llm: my_llm
)

step.return["result"]  #=> 32
```

The LLM may call multiple tools per turn or across multiple turns.

## Tool Signatures

Tool signatures define the JSON Schema sent to the LLM provider. Use the same signature syntax as PTC-Lisp tools:

```elixir
# Full tool definition with signature and description
"search" => {fn args -> do_search(args["query"]) end,
             signature: "(query :string, limit :int?) -> [{id :int, title :string}]",
             description: "Search the database"}

# Bare function (no schema sent to LLM — not recommended)
"ping" => fn _args -> "pong" end
```

Optional parameters (`:int?`) are excluded from the `required` list in the generated JSON Schema.

## Limits and Error Handling

### max_turns

Controls total LLM round-trips. Each tool call response and each final answer attempt counts as a turn:

```elixir
SubAgent.new(
  prompt: "Find and analyze data",
  output: :tool_calling,
  signature: "() -> {analysis :string}",
  tools: tools,
  max_turns: 10  # Allow up to 10 LLM calls
)
```

If exhausted, returns `{:error, step}` with `step.fail.reason == :max_turns_exceeded`.

### max_tool_calls

Limits total tool executions across all turns:

```elixir
SubAgent.new(
  prompt: "Search for info",
  output: :tool_calling,
  signature: "() -> {answer :string}",
  tools: tools,
  max_tool_calls: 5  # No more than 5 total tool calls
)
```

When the limit is reached, remaining tool calls in the current turn receive an error message, and the LLM is informed.

### Tool Errors

Tool failures don't crash the agent. If a tool raises an exception or isn't found, the error is fed back to the LLM as a tool result, giving it a chance to recover:

```elixir
# Tool that may fail
"risky" => {fn _args -> raise "service unavailable" end,
            signature: "() -> :string",
            description: "Call external service"}
```

The LLM receives `{"error": "service unavailable"}` as the tool result and can adapt its approach.

## Comparison with Other Modes

| Aspect | PTC-Lisp | Tool Calling | JSON |
|--------|----------|-------------|------|
| Tool invocation | LLM writes Lisp | Provider-native API | No tools |
| Computation | Full Lisp runtime | None (tools only) | None |
| Memory | Accumulated across turns | Always `%{}` | N/A |
| System prompt | Full PTC-Lisp spec | Minimal | Minimal |
| Best for | Capable LLMs | Small/fast LLMs | No-tool tasks |
| Sandbox | Isolated BEAM process | Direct function calls | N/A |

## Piping Between Modes

Tool calling mode returns the standard `Step` struct. Combine with other modes:

```elixir
# Tool calling mode gathers data
gather = SubAgent.new(
  prompt: "Look up the population of {{city}}",
  output: :tool_calling,
  signature: "(city :string) -> {population :int, country :string}",
  tools: %{"lookup" => {&MyApp.lookup/1,
                        signature: "(city :string) -> {population :int, country :string}",
                        description: "Look up city data"}}
)

# JSON mode summarizes (no tools needed)
summarize = SubAgent.new(
  prompt: "Write a one-sentence summary about {{city}} (pop: {{population}}, in {{country}})",
  output: :json,
  signature: "(city :string, population :int, country :string) -> {summary :string}"
)

{:ok, step1} = SubAgent.run(gather, context: %{city: "Tokyo"}, llm: llm)
{:ok, step2} = SubAgent.run(summarize, context: step1, llm: llm)
```

## See Also

- [Getting Started](subagent-getting-started.md) - Basic SubAgent usage
- [JSON Mode Guide](subagent-json-mode.md) - Structured output without tools
- [Core Concepts](subagent-concepts.md) - Context, memory, and data flow
- [Signature Syntax](../signature-syntax.md) - Full type syntax reference
- `PtcRunner.SubAgent.run/2` - API reference
- `PtcRunner.SubAgent.Loop.ToolCallingMode.run/3` - Tool calling execution loop
- `PtcRunner.SubAgent.ToolSchema.to_tool_definitions/1` - Tool schema conversion
