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

3. **Enable compression** for multi-turn agents:
   ```elixir
   PtcRunner.SubAgent.run(prompt,
     compression: true,  # Coalesces history into single USER message
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
│   (def results (ctx/search {:q "test"}))
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
   (def cached-data (ctx/fetch-data {}))
   ```

2. **Store and return different values**:
   ```clojure
   ;; Persists cached-data, returns a summary
   (do
     (def cached-data (ctx/fetch-data {}))
     (str "Stored " (count cached-data) " items"))
   ```

3. **Access stored values as plain symbols**:
   ```clojure
   ;; Access previously stored value
   cached-data
   ```

See [Core Concepts](subagent-concepts.md) for the full state persistence documentation.

## Side Effects Lost in Parallel/HOF Execution

**Symptom:** `println` output or tool calls inside `pmap`, `map`, `filter`, or other higher-order functions don't appear in the trace.

**Cause:** When closures are passed to higher-order functions (HOFs) or executed in parallel (`pmap`, `pcalls`), side effects like `println` and tool calls are discarded. This is a known limitation of the current architecture.

**Why this happens:** Higher-order functions convert PTC-Lisp closures to Erlang functions for execution. The evaluation context (which tracks prints and tool calls) is not threaded back from these function calls. For parallel execution, merging side effects from multiple concurrent branches would require complex ordering semantics.

**Solutions:**

1. **Use `doseq` for side-effectful iterations:**
   ```clojure
   ;; DON'T: println inside map (output lost)
   (map (fn [x] (println x) (+ x 1)) items)

   ;; DO: Use doseq for side effects
   (doseq [x items] (println x))
   (map (fn [x] (+ x 1)) items)
   ```

2. **Separate side effects from transformations:**
   ```clojure
   ;; Process data first
   (def results (map process-item items))
   ;; Then observe
   (println "Processed:" (count results))
   ```

3. **For debugging parallel code**, use explicit `println` before/after parallel operations:
   ```clojure
   (println "Starting parallel processing...")
   (def results (pmap expensive-fn items))
   (println "Finished with" (count results) "results")
   ```

**Note:** This limitation only affects observability (what appears in the trace). The actual computation results from closures are returned correctly. Tool calls inside parallel execution still execute - they just aren't tracked in the turn's tool call history.

## See Also

- [Getting Started](subagent-getting-started.md) - Basic SubAgent usage
- [Observability](subagent-observability.md) - Telemetry, debug mode, and tracing
- [Message Compression](subagent-compression.md) - Reduce context size in multi-turn agents
- [Core Concepts](subagent-concepts.md) - Context, memory, error handling
- [Testing](subagent-testing.md) - Mock LLMs and debug strategies
- `PtcRunner.SubAgent` - API reference
