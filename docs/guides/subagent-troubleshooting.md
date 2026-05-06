# Troubleshooting SubAgents

Common issues and solutions when working with SubAgents.

## Agent Loops Until max_turns_exceeded

**Symptom:** Agent produces correct intermediate results but never returns, hitting `max_turns_exceeded`.

**Cause:** The agent is in loop mode but not calling `return` to complete.

**Solutions:**

1. **For single-shot tasks**, set `max_turns: 1`:
   ```elixir
   PtcRunner.SubAgent.run(prompt,
     max_turns: 1,  # Single expression, no explicit return needed
     llm: llm
   )
   ```

2. **For agentic tasks**, ensure your prompt guides the LLM to call `return`:
   ```elixir
   prompt = """
   Find the most expensive product.
   When done, call (return {:name "...", :price ...})
   """
   ```

3. **Check the trace** to see what the agent is doing:
   ```elixir
   {:error, step} = SubAgent.run(prompt, llm: llm)
   SubAgent.Debug.print_trace(step)
   ```

## Validation Errors (Wrong Return Type)

**Symptom:** `{:error, step}` with `step.fail.reason == :validation_error`.

**Cause:** The agent's return value doesn't match the signature.

**Solutions:**

1. **Check the signature syntax**:
   ```elixir
   # Output only
   signature: "{name :string, price :float}"

   # With optional fields
   signature: "{name :string, price :float?}"

   # Arrays
   signature: "[{id :int, name :string}]"
   ```

2. **Make the signature more lenient** if the LLM struggles:
   ```elixir
   # Instead of strict types
   signature: "{count :int}"

   # Allow any value (validate in Elixir)
   signature: "{count :any}"
   ```

3. **Inspect what the agent returned**:
   ```elixir
   {:error, step} = SubAgent.run(prompt, llm: llm)
   IO.inspect(step.fail, label: "Validation error")
   ```

## Tool Not Being Called

**Symptom:** Agent answers from "knowledge" instead of calling the provided tool.

**Cause:** The LLM doesn't understand when or how to use the tool.

**Solutions:**

1. **Add a clear description**:
   ```elixir
   tools = %{
     "get_products" => {&MyApp.Products.list/0,
       description: "Returns all products with name, price, and category fields."
     }
   }
   ```

2. **Be explicit in the prompt**:
   ```elixir
   prompt = "Use the get_products tool to find the most expensive item."
   ```

3. **Verify the tool appears in the system prompt**:
   You can preview the prompt before running:
   ```elixir
   preview = SubAgent.preview_prompt(agent, context: %{})
   IO.puts(preview.system)  # Should list available tools
   ```
   Or inspect it after execution:
   ```elixir
   SubAgent.Debug.print_trace(step, messages: true)
   ```

## Context Too Large

**Symptom:** LLM responses are slow, expensive, or truncated.

**Cause:** Too much data in context or return values.

**Solutions:**

1. **Use the firewall convention** for large data:
   ```elixir
   # _ids hidden from LLM prompts but available to programs
   signature: "{summary :string, _ids [:int]}"
   ```

2. **Set prompt limits**:
   ```elixir
   PtcRunner.SubAgent.run(prompt,
     prompt_limit: %{list: 3, string: 500},  # Truncate in prompts
     llm: llm
   )
   ```

3. **Enable compaction** for long-running multi-turn agents:
   ```elixir
   PtcRunner.SubAgent.run(prompt,
     compaction: true,  # Trims older turns once turn/token threshold is hit
     llm: llm
   )
   ```

4. **Process in stages** - fetch data in one agent, analyze in another:
   ```elixir
   {:ok, step1} = SubAgent.run("Fetch relevant data", tools: fetch_tools, ...)
   {:ok, step2} = SubAgent.run("Analyze this data", context: step1, ...)
   ```

## LLM Returns Prose Instead of Code

**Symptom:** The LLM explains what it would do instead of writing PTC-Lisp. You may see `MaxTurnsExceeded` errors with empty traces and no programs generated.

**Cause:** System prompt not being sent, model confusion, or using wrong code fence format.

**Solutions:**

1. **Enable message view** to see exactly what the LLM is receiving and returning:
   ```elixir
   {:error, step} = SubAgent.run(prompt, llm: llm)
   # Show full LLM messages including the system prompt
   SubAgent.Debug.print_trace(step, messages: true)
   ```
   With `messages: true`, you'll see the **System Prompt** (containing instructions and tool definitions), the actual LLM response, and what feedback was sent back. This is essential for verifying that the instructions and tool definitions are correctly formatted and sent to the LLM.

2. **Ensure your LLM callback includes the system prompt**:
   ```elixir
   llm = fn %{system: system, messages: messages} ->
     # system MUST be included - it contains PTC-Lisp instructions
     full_messages = [%{role: :system, content: system} | messages]
     call_llm(full_messages)
   end
   ```

3. **Preview the prompt** to verify it contains PTC-Lisp instructions:
   ```elixir
   preview = SubAgent.preview_prompt(agent, context: %{})
   String.contains?(preview.system, "PTC-Lisp")  #=> true
   ```

4. **Try a different model** - some models follow PTC-Lisp instructions better than others. See [Benchmark Evaluation](../benchmark-eval.md) for model comparisons.

## LLM Produces "thinking:" Text Before Code

**Symptom:** Traces show `thinking:` or reasoning prose before the code block, wasting tokens.

**Cause:** Some models emit reasoning text even when `thinking: false` (the default). The multi-turn prompt examples and output format instructions discourage this, and `strip_thinking/1` removes any prose before the code block from message history to prevent reinforcement. The raw response is preserved in traces for debugging.

**Diagnosis:** Check the `llm.start` events in trace JSONL files — they contain the full system prompt sent to the LLM. Verify the prompt includes "no text before or after the block":
```elixir
{:ok, step} = SubAgent.run(prompt, llm: llm)
# Inspect the system prompt from the first turn
[first_turn | _] = step.turns
first_turn.system_prompt  # Full prompt sent to LLM
```

**Solutions:**

1. **Verify prompt is up to date** — prompts in `priv/prompts/` are compiled in. After editing, run `mix compile --force`.

2. **Use `thinking: true`** if you *want* reasoning visible in traces for debugging. The thinking text will appear in raw responses but is still stripped from message history.

3. **Try a different model** — some models are more prone to emitting unsolicited reasoning text.

## Viewing Token Usage

To see token consumption for debugging or optimization:

```elixir
{:ok, step} = SubAgent.run(prompt, llm: llm)
SubAgent.Debug.print_trace(step, usage: true)
```

Output:
```
┌─ Usage ──────────────────────────────────────────────────┐
│   Input tokens:  3,107
│   Output tokens: 368
│   Total tokens:  3,475
│   System prompt: 2,329 (est.)
│   Duration:      1,234ms
│   Turns:         1
└──────────────────────────────────────────────────────────┘
```

Options can be combined: `print_trace(step, messages: true, usage: true)`.

## Viewing Println Output

When debugging multi-turn agents, `println` output appears in the trace under "Output:":

```elixir
{:ok, step} = SubAgent.run(prompt, llm: llm)
SubAgent.Debug.print_trace(step)
```

Output:
```
┌─ Turn 1 ────────────────────────────────────────────────┐
│ Program:
│   (def results (tool/search {:q "test"}))
│   (println "Found:" (count results))
│   results
│ Output:
│   Found: 42
│ Result:
│   [{:id 1, :name "..."}, ...]
└──────────────────────────────────────────────────────────┘
```

If you don't see "Output:" in the trace, either no `println` was called or the LLM didn't use it. The prompt (`lisp-addon-multi_turn.md`) documents that only `println` output is shown in feedback—expression results are not displayed.

## Parse Errors in Generated Code

**Symptom:** `{:error, {:parse_error, ...}}` from the sandbox.

**Cause:** LLM generated invalid PTC-Lisp syntax.

**Solutions:**

1. **Check common mistakes** (these are fed back to the LLM automatically):
   - Missing operator: `(where :status "active")` should be `(where :status = "active")`
   - Lists instead of vectors: `'(1 2 3)` should be `[1 2 3]`
   - Missing else branch: `(if cond then)` should be `(if cond then nil)`

2. **View raw LLM output** to see what the LLM generated:
   ```elixir
   {:error, step} = SubAgent.run(prompt, llm: llm)
   SubAgent.Debug.print_trace(step, raw: true)
   ```

3. **The agent retries automatically** - parse errors are shown to the LLM for correction. If it keeps failing, the prompt or model may need adjustment.

## Tool Errors

**Symptom:** `step.fail.reason == :tool_error`.

**Cause:** Your tool function raised an exception or returned `{:error, ...}`.

**Solutions:**

1. **Return `{:error, reason}` for expected failures**:
   ```elixir
   def get_user(%{id: id}) do
     case Repo.get(User, id) do
       nil -> {:error, "User #{id} not found"}
       user -> user
     end
   end
   ```

2. **Let unexpected errors crash** - they'll be logged and the agent will see a generic error.

3. **Test tools in isolation** before using with SubAgents:
   ```elixir
   MyApp.Tools.get_user(%{id: 123})  # Test directly
   ```

## State Not Persisting

**Symptom:** A stored value returns nil in subsequent turns.

**Cause:** The program didn't use `def` to store the value.

**Solutions:**

1. **Use `def` to persist values**:
   ```clojure
   ;; This persists cached-data for later access
   (def cached-data (tool/fetch-data {}))
   ```

2. **Store and return different values**:
   ```clojure
   ;; Persists cached-data, returns a summary
   (do
     (def cached-data (tool/fetch-data {}))
     (str "Stored " (count cached-data) " items"))
   ```

3. **Access stored values as plain symbols**:
   ```clojure
   ;; Access previously stored value
   cached-data
   ```

See [Core Concepts](subagent-concepts.md) for the full state persistence documentation.

## Parallel Execution and println

**Observation:** `println` output inside `pmap`, `pcalls`, or higher-order functions like `map` doesn't appear in the trace.

**This is intentional.** Parallel branches communicate via return values, not side effects.

**Design rationale:**

1. **Return values are the contract** - Child agents and parallel branches return their results. If you need to communicate something, include it in the return value.

2. **Ordering would be non-deterministic** - If 8 parallel tasks each called `println`, what order should they appear? Random ordering is worse than nothing.

3. **Trace files exist for debugging** - When tracing is enabled, each child SubAgent has its own trace file with its own `println` output.

4. **Simpler mental model** - Parallel branches are pure transformations. Use `println` for sequential debugging between turns.

**Patterns:**

```clojure
;; Parallel branches - communicate via return values
(def results (pmap (fn [chunk] (tool/process {:data chunk})) chunks))

;; Sequential debugging - println works normally
(println "Processing" (count chunks) "chunks...")
(def results (pmap process-fn chunks))
(println "Got" (count results) "results")

;; Side-effectful iteration - use doseq
(doseq [x items] (println "Item:" x))
```

**Note:** Tool calls inside parallel execution DO execute and return values correctly. They just aren't tracked in the parent turn's tool call history (telemetry events are still emitted).

## Agent Crashes with "maximum heap size reached"

**Symptom:** Agent crashes with Erlang error log showing `maximum heap size reached`.

**Cause:** The default heap limit (~10MB) is too small for the workload.

**Solution:** Set `max_heap` in the agent or pass as a run option:

```elixir
# Option 1: In agent definition
agent = SubAgent.new(
  prompt: "...",
  max_heap: 200_000_000  # ~1.6GB (in words, not bytes)
)

# Option 2: As run option (overrides agent setting)
SubAgent.run(agent,
  llm: llm,
  context: context,
  max_heap: 200_000_000
)

# Option 3: Application-wide default in config.exs
config :ptc_runner, default_max_heap: 200_000_000
```

Child agents automatically inherit this setting from their parent.

## `ptc_transport: :tool_call` issues

These troubleshooting entries apply only when an agent is constructed with
`ptc_transport: :tool_call`. The default (`ptc_transport: :content`) is
unaffected by everything below. For the full transport guide, see
[PTC-Lisp Transport](subagent-ptc-transport.md).

### `:llm_error` immediately after enabling `ptc_transport: :tool_call`

**Symptom:** `{:error, step}` with `step.fail.reason == :llm_error` and a
provider-side reason string mentioning that tool calling is unsupported (most
common with Ollama and openai-compat endpoints without native tool calling).

**Cause:** `:tool_call` requires a provider/model with native tool calling.
PtcRunner does **not** silently fall back to `:content` — that would obscure a
real capability mismatch.

**Solutions:**

1. **Switch to a tool-calling-capable model** (most Anthropic, OpenAI,
   Bedrock-hosted variants, and tool-calling models on OpenRouter qualify).
   See the per-provider table in
   [`usage-rules/llm-setup.md`](../../usage-rules/llm-setup.md#ptc_transport-tool_call-and-provider-tool-calling).

2. **Or drop `ptc_transport`** to use the default `:content` transport. It
   works on every provider PtcRunner supports.

   ```elixir
   # Was:
   SubAgent.new(prompt: "...", tools: tools, ptc_transport: :tool_call)

   # If you can't change the model:
   SubAgent.new(prompt: "...", tools: tools)  # implicit :content
   ```

### Agent returns fenced Clojure as content in `:tool_call` mode

**Symptom:** In `ptc_transport: :tool_call` you see assistant turns whose
content is a markdown ` ```clojure ` block instead of a `ptc_lisp_execute`
tool call. Traces show retry feedback rather than program execution.

**Cause:** The model is trying to use the `:content` transport (fenced code)
even though the agent is configured for `:tool_call`. **This is expected
behavior** — PtcRunner deliberately does *not* parse fenced code in
`:tool_call` mode. Instead, it sends targeted feedback telling the model to
call the `ptc_lisp_execute` tool with the program.

**Solutions:**

1. **Let the loop self-correct.** One turn of feedback is usually enough for
   the model to switch to the tool. Each fenced-content recovery turn does
   consume one `max_turns` slot, so leave headroom in `max_turns:`.

2. **If it persists across multiple turns,** the provider/model is poorly
   suited for `:tool_call` on this workload. Switch back to the default
   `ptc_transport: :content` — fenced code becomes the *correct* output again,
   and you skip an unnecessary recovery loop. `:content` is not a downgrade;
   it is the right transport for models that don't follow native tool-calling
   instructions reliably.

3. **Verify the system prompt is being sent.** If the model never sees the
   "use the `ptc_lisp_execute` tool" guidance, it will default to whatever
   output style it knows. Check
   [LLM Returns Prose Instead of Code](#llm-returns-prose-instead-of-code)
   above for diagnosis steps — they apply equally here.

### `:tool_call` mode is no faster than `:content` (or is slower)

**Symptom:** You enabled `ptc_transport: :tool_call` expecting a speedup and
saw the same latency, or worse, more LLM turns and higher cost.

**Cause:** This is by design. `:tool_call` is **not** a latency or cost
optimization. It trades extra LLM turns (call `ptc_lisp_execute`, get tool
result, return final answer) for native-tool-calling reliability on
providers/models where that is materially better than fenced-code parsing. A
workload that finishes in one `:content` turn typically takes two or three in
`:tool_call`.

**Solutions:**

1. **If latency or cost matters, use `:content`.** It is the default for a
   reason — *one program, one deterministic orchestration*, single LLM turn.

2. **Reach for `:tool_call` only when** native tool calling is materially more
   reliable on your provider/model, *or* when the workload genuinely needs
   iterative refinement (model inspects an intermediate result before writing
   the next program). Both cases are real, but neither is the common case.

3. **Measure before standardizing.** If you're not sure which transport fits a
   workload, run both on a representative input set and compare turn count
   plus cost. The transports are stable in either direction.

## See Also

- [Getting Started](subagent-getting-started.md) - Basic SubAgent usage
- [PTC-Lisp Transport](subagent-ptc-transport.md) - `ptc_transport: :content` vs `:tool_call`
- [Observability](subagent-observability.md) - Telemetry, debug mode, and tracing
- [Context Compaction](subagent-compaction.md) - Pressure-triggered trimming for long-running agents
- [Core Concepts](subagent-concepts.md) - Context, memory, error handling
- [Testing](subagent-testing.md) - Mock LLMs and debug strategies
- `PtcRunner.SubAgent` - API reference
