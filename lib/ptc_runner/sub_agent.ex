defmodule PtcRunner.SubAgent do
  @moduledoc """
  Agentic loop for LLM-driven PTC-Lisp execution.

  A SubAgent prompts an LLM to write programs, executes them in a sandbox,
  and loops until completion. Define agents with `new/1`, execute with `run/2`.

  ## Execution Modes

  | Mode | Condition | Behavior |
  |------|-----------|----------|
  | Single-shot | `max_turns == 1` and `tools == %{}` | One LLM call, expression returned |
  | Loop | Otherwise | Multi-turn with tools until `return` or `fail` |

  ## Examples

      # Simple single-shot
      {:ok, step} = SubAgent.run("What's 2 + 2?", llm: my_llm, max_turns: 1)
      step.return  #=> 4

      # With tools and signature
      agent = SubAgent.new(
        prompt: "Find expensive products",
        signature: "{name :string, price :float}",
        tools: %{"list_products" => &MyApp.list/0}
      )
      {:ok, step} = SubAgent.run(agent, llm: my_llm)

  ## See Also

  - [Getting Started](guides/subagent-getting-started.md) - Full walkthrough
  - [Core Concepts](guides/subagent-concepts.md) - Context and memory
  - [Patterns](guides/subagent-patterns.md) - Composition and orchestration
  - [Text Mode + PTC-Lisp Compute](guides/text-mode-ptc-compute.md) - Combined mode (`output: :text, ptc_transport: :tool_call`)
  - `new/1` - All struct fields and options
  - `run/2` - Runtime options and LLM registry
  - `chat/3` - Multi-turn chat with history threading
  - [Phoenix Streaming](guides/phoenix-streaming.md) - Real-time streaming in LiveView
  """

  alias PtcRunner.SubAgent.Definition
  alias PtcRunner.SubAgent.Runner

  @type t :: Definition.t()
  @type language_spec :: Definition.language_spec()
  @type system_prompt_opts :: Definition.system_prompt_opts()
  @type llm_response :: Definition.llm_response()
  @type llm_callback :: Definition.llm_callback()
  @type llm_registry :: Definition.llm_registry()
  @type compaction_opts :: Definition.compaction_opts()
  @type output_mode :: Definition.output_mode()
  @type format_options :: Definition.format_options()
  @type plan_step :: Definition.plan_step()

  @doc "Returns the default format options."
  defdelegate default_format_options(), to: Definition

  @doc """
  Returns true if the agent's return type is plain text (`:string` or no signature).

  Used by TextMode to decide between raw text and JSON response handling.

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "Hello", output: :text)
      iex> PtcRunner.SubAgent.text_return?(agent)
      true

      iex> agent = PtcRunner.SubAgent.new(prompt: "Get data", signature: "() -> {name :string}", output: :text)
      iex> PtcRunner.SubAgent.text_return?(agent)
      false
  """
  defdelegate text_return?(agent), to: Definition

  @doc """
  Creates a SubAgent struct from keyword options.

  Raises `ArgumentError` if validation fails (missing required fields or invalid types).

  ## Parameters

  - `opts` - Keyword list of options

  ## Required Options

  - `prompt` - String template describing what to accomplish (supports `{{placeholder}}` expansion)

  ## Optional Options

  - `signature` - String contract defining expected inputs and outputs
  - `tools` - Map of callable tools (default: %{})
  - `max_turns` - Positive integer for maximum LLM calls (default: 5)
  - `retry_turns` - Non-negative integer for extra turns in must-return mode (default: 0)
  - `prompt_limit` - Map with truncation config for LLM view
  - `timeout` - Positive integer for max milliseconds per Lisp execution (default: 5000)
  - `max_heap` - Positive integer for max heap size in words per Lisp execution (default: app config or 1,250,000 ~10MB)
  - `mission_timeout` - Positive integer for max milliseconds for entire execution
  - `llm_retry` - Map with infrastructure retry config
  - `llm` - Atom or function for optional LLM override
  - `system_prompt` - System prompt customization (map, function, or string)
  - `memory_limit` - Positive integer for max bytes for memory map (default: 1MB = 1,048,576 bytes)
  - `memory_strategy` - How to handle memory limit exceeded: `:strict` (fatal, default) or `:rollback` (roll back memory, feed error to LLM)
  - `name` - Short display name shown in traces and the ptc-viewer (e.g. `"meta_agent"`, `"task_agent"`)
  - `description` - String describing the agent's purpose (for external docs)
  - `field_descriptions` - Map of field names to descriptions for signature fields
  - `context_descriptions` - Map of context variable names to descriptions (shown in Data Inventory)
  - `format_options` - Keyword list controlling output truncation (merged with defaults)
  - `float_precision` - Non-negative integer for decimal places in floats (default: 2)
  - `compaction` - Pressure-triggered context compaction (see `t:compaction_opts/0`)
  - `pmap_timeout` - Positive integer for max milliseconds per `pmap` parallel operation (default: 5000)
  - `pmap_max_concurrency` - Positive integer for max concurrent tasks in pmap/pcalls (default: `System.schedulers_online() * 2`). Reduce to avoid overflowing connection pools or API rate limits.
  - `max_depth` - Positive integer for maximum recursion depth in nested agents (default: 3)
  - `turn_budget` - Positive integer for total turn budget across retries (default: 20)
  - `output` - Output mode: `:ptc_lisp` (default) or `:text`
  - `ptc_reference` - Combined-mode reference card: `:compact` (default; only valid value in v1)
  - `thinking` - Boolean enabling thinking section in output format (default: false)
  - `llm_query` - Boolean enabling LLM query mode (default: false)
  - `builtin_tools` - List of builtin tool families to enable (default: []). Available: `:grep` (adds grep and grep-n tools)
  - `plan` - List of plan steps (strings, `{id, description}` tuples, or keyword list)

  ## Returns

  A `SubAgent.t()` struct.

  ## Raises

  - `ArgumentError` - if prompt is missing or not a string, max_turns is not positive, tools is not a map, any optional field has an invalid type, or prompt placeholders don't match signature parameters (when signature is provided)

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "Analyze the data")
      iex> agent.prompt
      "Analyze the data"

      iex> email_tools = %{"list_emails" => fn _args -> [] end}
      iex> agent = PtcRunner.SubAgent.new(
      ...>   prompt: "Find urgent emails for {{user}}",
      ...>   signature: "(user :string) -> {count :int, ids [:int]}",
      ...>   tools: email_tools,
      ...>   max_turns: 10
      ...> )
      iex> agent.max_turns
      10
  """
  defdelegate new(opts), to: Definition

  @doc """
  Unwraps internal sentinel values from a search result.

  Handles:
  - `{:__ptc_return__, value}` -> `{:ok, step_with_raw_value}`
  - `{:__ptc_fail__, value}` -> `{:error, error_step}`

  Used by single-shot mode and compiled agents to provide clean results.
  """
  defdelegate unwrap_sentinels(step), to: Definition

  defdelegate effective_tools(agent), to: PtcRunner.SubAgent.BuiltinTools
  defdelegate expand_builtin_tools(families), to: PtcRunner.SubAgent.BuiltinTools

  @doc """
  Executes a SubAgent with the given options.

  Returns a `Step` struct containing the result, metrics, and execution trace.

  ## Parameters

  - `agent` - A `SubAgent.t()` struct or a string prompt (for convenience)
  - `opts` - Keyword list of runtime options

  ## Runtime Options

  - `llm` - Required. LLM callback function `(map() -> {:ok, String.t()} | {:error, term()})` or atom
  - `llm_registry` - Map of atom to LLM callback for atom-based LLM references (default: %{})
  - `context` - Map of input data (default: %{})
  - `debug` - Deprecated, no longer needed. Turn structs always capture `raw_response`.
    Use `SubAgent.Debug.print_trace(step, raw: true)` to view full LLM output.
  - `trace` - Trace collection mode (default: true):
    - `true` - Always collect trace in Step
    - `false` - Never collect trace
    - `:on_error` - Only include trace when execution fails
  - `llm_retry` - Optional map to configure retry behavior for transient LLM failures:
    - `max_attempts` - Maximum retry attempts (default: 1, meaning no retries unless explicitly configured)
    - `backoff` - Backoff strategy: `:exponential`, `:linear`, or `:constant` (default: `:exponential`)
    - `base_delay` - Base delay in milliseconds (default: 1000)
    - `retryable_errors` - List of error types to retry (default: `[:rate_limit, :timeout, :server_error]`)
  - `collect_messages` - Capture full conversation history in Step.messages (default: false).
    When enabled, messages are in OpenAI format: `[%{role: :system | :user | :assistant, content: String.t()}]`
  - Other options from agent definition can be overridden

  ## LLM Registry

  When using atom LLMs (like `:haiku` or `:sonnet`), provide an `llm_registry` map:

      registry = %{
        haiku: fn input -> MyApp.LLM.haiku(input) end,
        sonnet: fn input -> MyApp.LLM.sonnet(input) end
      }

      SubAgent.run(agent, llm: :sonnet, llm_registry: registry)

  The registry is automatically inherited by all child SubAgents, so you only need
  to provide it once at the top level.

  ## Returns

  - `{:ok, Step.t()}` on success
  - `{:error, Step.t()}` on failure

  ## Examples

      # Using a SubAgent struct
      iex> agent = PtcRunner.SubAgent.new(prompt: "Calculate {{x}} + {{y}}", max_turns: 1)
      iex> llm = fn %{messages: [%{content: _prompt}]} -> {:ok, "```clojure\\n(+ data/x data/y)\\n```"} end
      iex> {:ok, step} = PtcRunner.SubAgent.run(agent, llm: llm, context: %{x: 5, y: 3})
      iex> step.return
      8

      # Using string convenience form
      iex> llm = fn %{messages: [%{content: _prompt}]} -> {:ok, "```clojure\\n42\\n```"} end
      iex> {:ok, step} = PtcRunner.SubAgent.run("Return 42", max_turns: 1, llm: llm)
      iex> step.return
      42

      # Using atom LLM with registry
      iex> registry = %{test: fn %{messages: [%{content: _}]} -> {:ok, "```clojure\\n100\\n```"} end}
      iex> {:ok, step} = PtcRunner.SubAgent.run("Test", max_turns: 1, llm: :test, llm_registry: registry)
      iex> step.return
      100
  """
  @spec run(t() | String.t(), keyword()) ::
          {:ok, PtcRunner.Step.t()} | {:error, PtcRunner.Step.t()}
  def run(agent_or_prompt, opts \\ [])

  # String convenience form - creates agent inline
  def run(mission, opts) when is_binary(mission) do
    # Extract struct fields from opts
    struct_opts =
      opts
      |> Keyword.take([
        :signature,
        :tools,
        :llm_query,
        :builtin_tools,
        :max_turns,
        :retry_turns,
        :timeout,
        :pmap_timeout,
        :pmap_max_concurrency,
        :max_heap,
        :prompt_limit,
        :mission_timeout,
        :llm_retry,
        :llm,
        :system_prompt,
        :compaction,
        :thinking,
        :memory_limit,
        :max_depth,
        :turn_budget,
        :name,
        :description,
        :field_descriptions,
        :context_descriptions,
        :format_options,
        :float_precision,
        :output,
        :ptc_transport,
        :ptc_reference,
        :memory_strategy,
        :max_tool_calls,
        :plan,
        :journaling,
        :completion_mode
      ])
      |> Keyword.put(:prompt, mission)

    agent = new(struct_opts)

    # Remove struct opts and normalize to a %Definition{}, then run via the
    # internal runner.
    runtime_opts =
      Keyword.drop(opts, [
        :signature,
        :tools,
        :llm_query,
        :builtin_tools,
        :max_turns,
        :retry_turns,
        :prompt_limit,
        :mission_timeout,
        :llm_retry,
        :system_prompt,
        :mission,
        :compaction,
        :thinking,
        :memory_limit,
        :max_depth,
        :turn_budget,
        :name,
        :description,
        :field_descriptions,
        :context_descriptions,
        :format_options,
        :float_precision,
        :output,
        :ptc_transport,
        :ptc_reference,
        :memory_strategy,
        :max_tool_calls,
        :plan,
        :journaling,
        :completion_mode
      ])

    Runner.run(agent, runtime_opts)
  end

  # Main implementation with SubAgent struct - delegates to the internal runner
  def run(%Definition{} = agent, opts) do
    Runner.run(agent, opts)
  end

  # CompiledAgent execution - unified API
  def run(%PtcRunner.SubAgent.CompiledAgent{} = compiled, opts) when is_list(opts) do
    context = prepare_compiled_context(opts)

    if compiled.llm_required? and not Keyword.has_key?(opts, :llm) do
      {:error,
       PtcRunner.Step.error(
         :llm_required,
         "llm required for CompiledAgent with SubAgentTools",
         %{}
       )}
    else
      step = compiled.execute.(context, opts)
      if step.fail, do: {:error, step}, else: {:ok, step}
    end
  end

  @doc """
  Bang variant of `run/2` that raises on failure.

  Returns the `Step` struct directly instead of `{:ok, step}`. Raises
  `SubAgentError` if execution fails.

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "Say hello", max_turns: 1)
      iex> mock_llm = fn _ -> {:ok, "```clojure\\n\\\"Hello!\\\"\\n```"} end
      iex> step = PtcRunner.SubAgent.run!(agent, llm: mock_llm)
      iex> step.return
      "Hello!"

      # Failure case (using loop mode)
      iex> agent = PtcRunner.SubAgent.new(prompt: "Fail", max_turns: 2)
      iex> mock_llm = fn _ -> {:ok, ~S|(fail {:reason :test :message "Error"})|} end
      iex> PtcRunner.SubAgent.run!(agent, llm: mock_llm)
      ** (PtcRunner.SubAgentError) SubAgent failed: failed - %{"message" => "Error", "reason" => "test"}

  """
  @spec run!(t() | String.t(), keyword()) :: PtcRunner.Step.t()
  def run!(agent, opts \\ []) do
    case run(agent, opts) do
      {:ok, step} -> step
      {:error, step} -> raise PtcRunner.SubAgentError, %{step: step}
    end
  end

  @doc """
  Multi-turn chat with conversation history threading.

  Wraps `run/2` for chat use cases where conversation history must persist
  across calls. Auto-detects mode based on `agent.output`:

  - **`:text`** — Forces text mode, clears signature. Returns plain text.
  - **`:ptc_lisp`** — Keeps PTC-Lisp mode and signature. Returns structured data
    and memory (variables defined via `def`).

  ## Parameters

  - `agent` - A `SubAgent.t()` struct
  - `user_message` - The user's message for this turn
  - `opts` - Runtime options (same as `run/2`, plus `:messages` and `:memory`)

  ## Options

  - `:messages` - Prior conversation history (default: `[]`). Pass the
    `updated_messages` from a previous `chat/3` call to continue the conversation.
  - `:memory` - Prior memory map (default: `%{}`). For PTC-Lisp mode, pass the
    memory from a previous `chat/3` call so the LLM can access prior variables.
  - All other options are forwarded to `run/2` (e.g., `:llm`, `:context`)

  ## Returns

  - `{:ok, result, updated_messages, memory}` — the result (text or structured),
    the full message history, and the memory map (empty for text mode)
  - `{:error, reason}` — on failure

  ## Examples

      # Text mode
      agent = SubAgent.new(
        prompt: "placeholder",
        output: :text,
        system_prompt: "You are a helpful assistant."
      )

      {:ok, reply, messages, _memory} = SubAgent.chat(agent, "Hello!", llm: my_llm)
      {:ok, reply2, messages2, _memory} = SubAgent.chat(
        agent, "Tell me more",
        llm: my_llm, messages: messages
      )

      # PTC-Lisp mode with memory threading
      agent = SubAgent.new(
        prompt: "placeholder",
        output: :ptc_lisp,
        system_prompt: "You are a helpful assistant.",
        tools: my_tools
      )

      {:ok, result, messages, memory} = SubAgent.chat(agent, "Look up X", llm: my_llm)
      {:ok, result2, messages2, memory2} = SubAgent.chat(
        agent, "Now use that result",
        llm: my_llm, messages: messages, memory: memory
      )
  """
  @spec chat(t(), String.t(), keyword()) ::
          {:ok, term(), [map()], map()} | {:error, term()}
  def chat(%Definition{} = agent, user_message, opts \\ []) do
    {history, opts} = Keyword.pop(opts, :messages, [])
    {memory, opts} = Keyword.pop(opts, :memory, %{})

    # Strip system messages from history — the loop regenerates the system prompt
    initial_messages =
      Enum.reject(history, fn msg -> msg[:role] == :system end)

    case agent.output do
      :text ->
        # Force text mode and clear any signature — returns plain text.
        agent = %{
          agent
          | prompt: user_message,
            output: :text,
            signature: nil,
            parsed_signature: nil
        }

        run_opts =
          opts
          |> Keyword.put(:collect_messages, true)
          |> Keyword.put(:initial_messages, initial_messages)

        case run(agent, run_opts) do
          {:ok, step} ->
            {:ok, step.return, step.messages, %{}}

          {:error, step} ->
            {:error, step.fail || step}
        end

      :ptc_lisp ->
        # PTC-Lisp mode — keep output/signature, thread memory
        agent = %{agent | prompt: user_message}

        run_opts =
          opts
          |> Keyword.put(:collect_messages, true)
          |> Keyword.put(:initial_messages, initial_messages)
          |> Keyword.put(:initial_memory, memory)

        case run(agent, run_opts) do
          {:ok, step} ->
            {:ok, step.return, step.messages, step.memory}

          {:error, step} ->
            {:error, step.fail || step}
        end
    end
  end

  @doc """
  Chains agents in a pipeline, passing the previous step as context.

  See `PtcRunner.SubAgent.Chaining.then!/3` for full documentation.
  """
  defdelegate then!(step, agent, opts \\ []), to: PtcRunner.SubAgent.Chaining

  @doc """
  Chains SubAgent/CompiledAgent executions with error propagation.

  See `PtcRunner.SubAgent.Chaining.then/3` for full documentation.
  """
  defdelegate then(result, agent, opts \\ []), to: PtcRunner.SubAgent.Chaining

  # Prepare context from opts for CompiledAgent execution
  defp prepare_compiled_context(opts) do
    case Keyword.get(opts, :context, %{}) do
      %PtcRunner.Step{fail: nil, return: return} when is_map(return) -> return
      %PtcRunner.Step{fail: nil, return: _} -> %{}
      %PtcRunner.Step{fail: _} -> %{}
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc """
  Wraps a SubAgent as a tool callable by other agents.

  Returns a `SubAgentTool` struct that parent agents can include
  in their tools map. When called, the wrapped agent inherits
  LLM and registry from the parent unless overridden.

  ## Options

  - `:llm` - Bind specific LLM (atom or function). Overrides parent inheritance.
  - `:description` - Override agent's description (falls back to `agent.description`)
  - `:name` - Suggested tool name (informational, not enforced by the struct)
  - `:cache` - Cache results by input args (default: `false`). Only use for
    deterministic agents where same inputs always produce same outputs.

  ## Description Requirement

  A description is required for tools. It can be provided either:
  - On the SubAgent via `new(description: "...")`, or
  - Via the `:description` option when calling `as_tool/2`

  Raises `ArgumentError` if neither is provided.

  ## LLM Resolution

  When the tool is called, the LLM is resolved in priority order:
  1. `agent.llm` - The agent's own LLM override (highest priority)
  2. `bound_llm` - LLM bound via the `:llm` option
  3. Parent's llm - Inherited from the calling agent (lowest priority)

  ## Examples

      iex> child = PtcRunner.SubAgent.new(
      ...>   prompt: "Double {{n}}",
      ...>   signature: "(n :int) -> {result :int}",
      ...>   description: "Doubles a number"
      ...> )
      iex> tool = PtcRunner.SubAgent.as_tool(child)
      iex> tool.signature
      "(n :int) -> {result :int}"
      iex> tool.description
      "Doubles a number"

      iex> child = PtcRunner.SubAgent.new(prompt: "Process data", description: "Default desc")
      iex> tool = PtcRunner.SubAgent.as_tool(child, llm: :haiku, description: "Processes data")
      iex> tool.bound_llm
      :haiku
      iex> tool.description
      "Processes data"

      iex> child = PtcRunner.SubAgent.new(prompt: "Analyze {{text}}", signature: "(text :string) -> :string", description: "Analyzes text")
      iex> tool = PtcRunner.SubAgent.as_tool(child, name: "analyzer")
      iex> tool.signature
      "(text :string) -> :string"

      iex> child = PtcRunner.SubAgent.new(prompt: "No description")
      iex> PtcRunner.SubAgent.as_tool(child)
      ** (ArgumentError) as_tool requires description to be set - pass description: option or set description on the SubAgent

  """
  @spec as_tool(t(), keyword()) :: PtcRunner.SubAgent.SubAgentTool.t()
  def as_tool(%Definition{} = agent, opts \\ []) do
    alias PtcRunner.SubAgent.SubAgentTool

    description = Keyword.get(opts, :description) || agent.description

    unless description do
      raise ArgumentError,
            "as_tool requires description to be set - pass description: option or set description on the SubAgent"
    end

    %SubAgentTool{
      agent: agent,
      bound_llm: Keyword.get(opts, :llm),
      signature: agent.signature,
      description: description,
      cache: Keyword.get(opts, :cache, false)
    }
  end

  @doc "See `PtcRunner.SubAgent.Compiler.compile/2`."
  defdelegate compile(agent, opts), to: PtcRunner.SubAgent.Compiler

  @doc """
  Preview the system and user prompts that would be sent to the LLM.

  This function generates and returns the prompts without executing the agent,
  useful for debugging prompt generation, verifying template expansion, and
  reviewing what the LLM will see.

  ## Parameters

  - `agent` - A `SubAgent.t()` struct
  - `opts` - Keyword list with:
    - `context` - Context map for template expansion (default: %{})

  ## Returns

  A map with:
  - `:system` - The static system prompt (cacheable - does NOT include mission)
  - `:user` - The full first user message (context sections + mission)
  - `:tool_schemas` - List of tool schema maps with name, signature, and description fields
  - `:schema` - JSON schema for the return type (text mode only, nil for PTC-Lisp)

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(
      ...>   prompt: "Find emails for {{user}}",
      ...>   signature: "(user :string) -> {count :int}",
      ...>   tools: %{"list_emails" => fn _ -> [] end}
      ...> )
      iex> preview = PtcRunner.SubAgent.preview_prompt(agent, context: %{user: "alice"})
      iex> preview.user =~ "Find emails for alice"
      true
      iex> preview.user =~ "<mission>"
      true
      iex> preview.system =~ "<return_rules>"
      true
      iex> preview.system =~ "<mission>"
      false

  """
  @spec preview_prompt(t(), keyword()) :: %{
          system: String.t(),
          user: String.t(),
          tool_schemas: [map()],
          schema: map() | nil
        }

  def preview_prompt(%Definition{} = agent, opts \\ []) do
    alias PtcRunner.SubAgent.Loop.TextMode

    context = Keyword.get(opts, :context, %{})

    case agent.output do
      :text ->
        TextMode.preview_prompt(agent, context)

      _ptc_lisp ->
        preview_prompt_ptc_lisp(agent, context)
    end
  end

  # PTC-Lisp mode preview (original implementation)
  defp preview_prompt_ptc_lisp(agent, context) do
    alias PtcRunner.SubAgent.{PromptExpander, SystemPrompt}

    # Resolve :self tools before generating prompts so the context includes proper signatures
    resolved_tools = Runner.resolve_self_tools(agent.tools, agent)
    agent_with_resolved_tools = %{agent | tools: resolved_tools}

    # Generate system prompt - static sections only (matches what Loop sends)
    # This is cacheable because it doesn't include the mission
    system_prompt = SystemPrompt.generate_system(agent_with_resolved_tools)

    # Expand the mission template
    {:ok, expanded_mission} = PromptExpander.expand(agent.prompt, context, on_missing: :keep)

    # Generate context sections (data inventory, tools, expected output)
    context_prompt = SystemPrompt.generate_context(agent_with_resolved_tools, context: context)

    # Combine context with mission (matches what Loop sends as first user message)
    user_message =
      [context_prompt, "<mission>\n#{expanded_mission}\n</mission>"]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    # Tool schemas - extract from resolved tools
    tool_schemas =
      resolved_tools
      |> Enum.map(fn {name, format} ->
        case PtcRunner.Tool.new(name, format) do
          {:ok, tool} ->
            schema = %{name: tool.name}

            schema =
              if tool.signature, do: Map.put(schema, :signature, tool.signature), else: schema

            schema =
              if tool.description,
                do: Map.put(schema, :description, tool.description),
                else: schema

            schema

          {:error, _} ->
            # Fallback for tools that fail normalization
            %{name: name}
        end
      end)

    %{
      system: system_prompt,
      user: user_message,
      tool_schemas: tool_schemas,
      schema: nil
    }
  end
end
