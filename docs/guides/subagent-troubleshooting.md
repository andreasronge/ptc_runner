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
   {:error, step} = SubAgent.run(prompt, debug: true, llm: llm)
   SubAgent.Debug.print_trace(step.trace)
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
   {:error, step} = SubAgent.run(prompt, debug: true, llm: llm)
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
   ```elixir
   preview = SubAgent.preview_prompt(agent, context: %{})
   IO.puts(preview.system)  # Should list available tools
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

3. **Process in stages** - fetch data in one agent, analyze in another:
   ```elixir
   {:ok, step1} = SubAgent.run("Fetch relevant data", tools: fetch_tools, ...)
   {:ok, step2} = SubAgent.run("Analyze this data", context: step1, ...)
   ```

## LLM Returns Prose Instead of Code

**Symptom:** The LLM explains what it would do instead of writing PTC-Lisp.

**Cause:** System prompt not being sent or model confusion.

**Solutions:**

1. **Ensure your LLM callback includes the system prompt**:
   ```elixir
   llm = fn %{system: system, messages: messages} ->
     # system MUST be included - it contains PTC-Lisp instructions
     full_messages = [%{role: :system, content: system} | messages]
     call_llm(full_messages)
   end
   ```

2. **Preview the prompt** to verify it contains PTC-Lisp instructions:
   ```elixir
   preview = SubAgent.preview_prompt(agent, context: %{})
   String.contains?(preview.system, "PTC-Lisp")  #=> true
   ```

3. **Try a different model** - some models follow PTC-Lisp instructions better than others. See [Benchmark Evaluation](../benchmark-eval.md) for model comparisons.

## Parse Errors in Generated Code

**Symptom:** `{:error, {:parse_error, ...}}` from the sandbox.

**Cause:** LLM generated invalid PTC-Lisp syntax.

**Solutions:**

1. **Check common mistakes** (these are fed back to the LLM automatically):
   - Missing operator: `(where :status "active")` should be `(where :status = "active")`
   - Lists instead of vectors: `'(1 2 3)` should be `[1 2 3]`
   - Missing else branch: `(if cond then)` should be `(if cond then nil)`

2. **Enable debug mode** to see raw LLM output:
   ```elixir
   {:error, step} = SubAgent.run(prompt, debug: true, llm: llm)
   SubAgent.Debug.print_trace(step.trace)
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

## Memory Not Persisting

**Symptom:** `memory/key` returns nil in subsequent turns.

**Cause:** The program didn't return a map, or returned it incorrectly.

**Solutions:**

1. **Return a map to persist values**:
   ```clojure
   ;; This persists :cached_data to memory
   {:cached_data (call "fetch_data" {})}
   ```

2. **Use :result to separate return value from memory**:
   ```clojure
   ;; Persists :cached_data, returns 42
   {:cached_data (call "fetch_data" {})
    :result 42}
   ```

3. **Non-maps don't update memory**:
   ```clojure
   ;; This just returns the count, no memory update
   (count ctx/items)
   ```

See [Core Concepts](subagent-concepts.md) for the full memory result contract.

## See Also

- [Getting Started](subagent-getting-started.md) - Basic SubAgent usage
- [Core Concepts](subagent-concepts.md) - Context, memory, error handling
- [Testing](subagent-testing.md) - Mock LLMs and debug strategies
- `PtcRunner.SubAgent` - API reference
