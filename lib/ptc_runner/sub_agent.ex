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
  - [Core Concepts](guides/subagent-concepts.md) - Context, memory, firewall
  - [Patterns](guides/subagent-patterns.md) - Composition and orchestration
  - `new/1` - All struct fields and options
  - `run/2` - Runtime options and LLM registry
  """

  @typedoc """
  Language spec for system prompts.

  Can be:
  - String: used as-is
  - Atom: resolved via `PtcRunner.Lisp.LanguageSpec.get!/1` (e.g., `:minimal`, `:default`)
  - Function: callback receiving context map with `:turn`, `:model`, `:memory`, `:messages`
  """
  @type language_spec :: String.t() | atom() | (map() -> String.t())

  @type system_prompt_opts ::
          %{
            optional(:prefix) => String.t(),
            optional(:suffix) => String.t(),
            optional(:language_spec) => language_spec(),
            optional(:output_format) => String.t()
          }
          | (String.t() -> String.t())
          | String.t()

  @typedoc """
  LLM response format.

  Can be either a plain string (backward compatible) or a map with content and optional tokens.
  When tokens are provided, they are included in telemetry measurements and accumulated in Step.usage.
  """
  @type llm_response ::
          String.t()
          | %{
              required(:content) => String.t(),
              optional(:tokens) => %{
                optional(:input) => pos_integer(),
                optional(:output) => pos_integer()
              }
            }

  @type llm_callback :: (map() -> {:ok, llm_response()} | {:error, term()})

  @type llm_registry :: %{atom() => llm_callback()}

  @typedoc """
  Compression strategy configuration.

  Can be:
  - `nil` or `false` - Compression disabled (default)
  - `true` - Use default strategy (`SingleUserCoalesced`) with default options
  - `Module` - Use custom strategy module with default options
  - `{Module, opts}` - Use custom strategy module with custom options

  See `PtcRunner.SubAgent.Compression` for details.
  """
  @type compression_opts :: nil | false | true | module() | {module(), keyword()}

  @typedoc """
  Output mode for SubAgent execution.

  - `:ptc_lisp` - Default. LLM generates PTC-Lisp code that is executed.
  - `:json` - LLM generates JSON directly matching the signature's return type.
  """
  @type output_mode :: :ptc_lisp | :json

  @typedoc """
  Output format options for truncation and display.

  Fields:
  - `feedback_limit` - Max collection items in turn feedback (default: 10)
  - `feedback_max_chars` - Max chars in turn feedback (default: 512)
  - `history_max_bytes` - Truncation limit for `*1/*2/*3` history (default: 512)
  - `result_limit` - Inspect `:limit` for final result (default: 50)
  - `result_max_chars` - Final string truncation (default: 500)
  - `max_print_length` - Max chars per `println` call (default: 2000)
  """
  @type format_options :: [
          feedback_limit: pos_integer(),
          feedback_max_chars: pos_integer(),
          history_max_bytes: pos_integer(),
          result_limit: pos_integer(),
          result_max_chars: pos_integer(),
          max_print_length: pos_integer()
        ]

  @typedoc """
  Plan step definition.

  Each step is a `{id, description}` tuple where:
  - `id` is a string identifier (used as key in summaries)
  - `description` is a human-readable description of the step
  """
  @type plan_step :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          prompt: String.t(),
          signature: String.t() | nil,
          parsed_signature: {:signature, list(), term()} | nil,
          tools: map(),
          llm_query: boolean(),
          builtin_tools: [atom()],
          max_turns: pos_integer(),
          retry_turns: non_neg_integer(),
          prompt_limit: map() | nil,
          timeout: pos_integer(),
          max_heap: pos_integer() | nil,
          mission_timeout: pos_integer() | nil,
          llm_retry: map() | nil,
          llm: atom() | (map() -> {:ok, llm_response()} | {:error, term()}) | nil,
          system_prompt: system_prompt_opts() | nil,
          memory_limit: pos_integer() | nil,
          max_depth: pos_integer(),
          turn_budget: pos_integer(),
          description: String.t() | nil,
          field_descriptions: map() | nil,
          context_descriptions: map() | nil,
          format_options: format_options(),
          float_precision: non_neg_integer(),
          compression: compression_opts(),
          output: output_mode(),
          memory_strategy: :strict | :rollback,
          plan: [plan_step()]
        }

  alias PtcRunner.SubAgent.KeyNormalizer
  alias PtcRunner.SubAgent.LLMResolver
  alias PtcRunner.SubAgent.Telemetry
  alias PtcRunner.TraceLog.Collector

  @default_format_options [
    feedback_limit: 10,
    feedback_max_chars: 512,
    history_max_bytes: 512,
    result_limit: 50,
    result_max_chars: 500,
    max_print_length: 2000
  ]

  defstruct [
    :prompt,
    :signature,
    :parsed_signature,
    :schema,
    :prompt_limit,
    :max_heap,
    :mission_timeout,
    :llm_retry,
    :llm,
    :system_prompt,
    :description,
    :field_descriptions,
    :context_descriptions,
    :compression,
    tools: %{},
    llm_query: false,
    builtin_tools: [],
    max_turns: 5,
    retry_turns: 0,
    timeout: 5000,
    pmap_timeout: 5000,
    memory_limit: 1_048_576,
    max_depth: 3,
    turn_budget: 20,
    format_options: @default_format_options,
    float_precision: 2,
    output: :ptc_lisp,
    memory_strategy: :strict,
    plan: []
  ]

  @doc "Returns the default format options."
  @spec default_format_options() :: format_options()
  def default_format_options, do: @default_format_options

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
  - `description` - String describing the agent's purpose (for external docs)
  - `field_descriptions` - Map of field names to descriptions for signature fields
  - `context_descriptions` - Map of context variable names to descriptions (shown in Data Inventory)
  - `format_options` - Keyword list controlling output truncation (merged with defaults)
  - `float_precision` - Non-negative integer for decimal places in floats (default: 2)
  - `compression` - Compression strategy for turn history (see `t:compression_opts/0`)
  - `pmap_timeout` - Positive integer for max milliseconds per `pmap` parallel operation (default: 5000)
  - `max_depth` - Positive integer for maximum recursion depth in nested agents (default: 3)
  - `turn_budget` - Positive integer for total turn budget across retries (default: 20)
  - `output` - Output mode: `:ptc_lisp` (default) or `:json`
  - `llm_query` - Boolean enabling LLM query mode (default: false)
  - `builtin_tools` - List of builtin tool families to enable (default: []). Available: `:grep` (adds grep and grep-n tools)
  - `plan` - List of plan steps (strings, `{id, description}` tuples, or keyword list)

  ## Returns

  A `%SubAgent{}` struct.

  ## Raises

  - `ArgumentError` - if prompt is missing or not a string, max_turns is not positive, tools is not a map, any optional field has an invalid type, or prompt placeholders don't match signature parameters (when signature is provided)

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "Analyze the data")
      iex> agent.prompt
      "Analyze the data"

      iex> email_tools = %{"list_emails" => fn _args -> [] end}
      iex> agent = PtcRunner.SubAgent.new(
      ...>   prompt: "Find urgent emails for {{user}}",
      ...>   signature: "(user :string) -> {count :int, _ids [:int]}",
      ...>   tools: email_tools,
      ...>   max_turns: 10
      ...> )
      iex> agent.max_turns
      10
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    alias PtcRunner.SubAgent.{Signature, Validator}
    Validator.validate!(opts)

    # Parse signature if provided (cached for loop return validation)
    # Note: Validator.validate! already ensures signature parses correctly
    opts =
      case Keyword.fetch(opts, :signature) do
        {:ok, sig_str} when is_binary(sig_str) ->
          {:ok, parsed} = Signature.parse(sig_str)
          Keyword.put(opts, :parsed_signature, parsed)

        _ ->
          opts
      end

    # Merge format_options with defaults (user values override)
    opts =
      case Keyword.fetch(opts, :format_options) do
        {:ok, user_opts} when is_list(user_opts) ->
          merged = Keyword.merge(@default_format_options, user_opts)
          Keyword.put(opts, :format_options, merged)

        _ ->
          opts
      end

    # Normalize and validate plan to [{id, description}] format
    opts =
      case Keyword.fetch(opts, :plan) do
        {:ok, plan} when is_list(plan) ->
          Keyword.put(opts, :plan, normalize_plan(plan))

        {:ok, _} ->
          raise ArgumentError, "plan must be a list"

        :error ->
          opts
      end

    struct(__MODULE__, opts)
  end

  # Normalize plan: accept ["step1", "step2"] or [{"id", "desc"}, ...] or keyword list
  # Also validates — raises ArgumentError on bad input
  defp normalize_plan(plan) do
    normalized =
      plan
      |> Enum.with_index(1)
      |> Enum.map(fn
        {{id, desc}, _idx} when is_binary(id) and is_binary(desc) ->
          if desc == "",
            do: raise(ArgumentError, "plan description cannot be empty for id #{inspect(id)}")

          {id, desc}

        {{id, desc}, _idx} when is_atom(id) and is_binary(desc) ->
          if desc == "",
            do: raise(ArgumentError, "plan description cannot be empty for id #{inspect(id)}")

          {to_string(id), desc}

        {desc, idx} when is_binary(desc) ->
          if desc == "", do: raise(ArgumentError, "plan description cannot be empty")
          {to_string(idx), desc}

        {other, _idx} ->
          raise ArgumentError, "invalid plan item: #{inspect(other)}"
      end)

    # Check for duplicate IDs
    ids = Enum.map(normalized, fn {id, _} -> id end)
    dupes = ids -- Enum.uniq(ids)

    if dupes != [] do
      raise ArgumentError, "duplicate plan IDs: #{inspect(Enum.uniq(dupes))}"
    end

    normalized
  end

  @builtin_tool_families %{
    grep: [{"grep", :builtin_grep}, {"grep-n", :builtin_grep_n}]
  }

  @doc """
  Returns the agent's tools with builtin tools injected.

  Merges `llm_query` and `builtin_tools` families into the tools map.
  User-defined tools are never overwritten by builtins.

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "test", builtin_tools: [:grep])
      iex> tools = PtcRunner.SubAgent.effective_tools(agent)
      iex> Map.has_key?(tools, "grep")
      true

      iex> agent = PtcRunner.SubAgent.new(prompt: "test", builtin_tools: [:grep], tools: %{"grep" => fn _ -> :custom end})
      iex> tools = PtcRunner.SubAgent.effective_tools(agent)
      iex> is_function(tools["grep"])
      true
  """
  @spec effective_tools(t()) :: map()
  def effective_tools(%__MODULE__{} = agent) do
    tools = agent.tools

    # Use Map.put_new to avoid overwriting user-defined tools
    tools =
      if agent.llm_query,
        do: Map.put_new(tools, "llm-query", :builtin_llm_query),
        else: tools

    # Expand builtin_tools families
    Enum.reduce(agent.builtin_tools, tools, fn family, acc ->
      case Map.fetch(@builtin_tool_families, family) do
        {:ok, entries} ->
          Enum.reduce(entries, acc, fn {name, sentinel}, inner_acc ->
            Map.put_new(inner_acc, name, sentinel)
          end)

        :error ->
          acc
      end
    end)
  end

  @doc """
  Executes a SubAgent with the given options.

  Returns a `Step` struct containing the result, metrics, and execution trace.

  ## Parameters

  - `agent` - A `%SubAgent{}` struct or a string prompt (for convenience)
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
        :max_heap,
        :prompt_limit,
        :mission_timeout,
        :llm_retry,
        :llm,
        :system_prompt,
        :compression,
        :memory_limit,
        :max_depth,
        :turn_budget,
        :description,
        :field_descriptions,
        :context_descriptions,
        :format_options,
        :float_precision,
        :output,
        :memory_strategy,
        :plan
      ])
      |> Keyword.put(:prompt, mission)

    agent = new(struct_opts)

    # Remove struct opts and pass runtime opts
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
        :compression,
        :memory_limit,
        :max_depth,
        :turn_budget,
        :description,
        :field_descriptions,
        :context_descriptions,
        :format_options,
        :float_precision,
        :output,
        :memory_strategy,
        :plan
      ])

    run(agent, runtime_opts)
  end

  # Main implementation with SubAgent struct
  def run(%__MODULE__{} = agent, opts) do
    # Auto-inject trace_context if TraceLog is active but trace_context not provided
    opts = maybe_inject_trace_context(opts)

    # Resolve :self tools before execution so they have proper signatures in prompts
    agent =
      if Enum.any?(agent.tools, fn {_, v} -> v == :self end) do
        %{agent | tools: resolve_self_tools(agent.tools, agent)}
      else
        agent
      end

    start_time = System.monotonic_time(:millisecond)

    # Validate required llm option
    llm = Keyword.get(opts, :llm) || agent.llm

    # Validate llm_registry if provided
    llm_registry = Keyword.get(opts, :llm_registry, %{})

    with :ok <- validate_llm_presence(llm, start_time),
         :ok <- validate_llm_registry(llm_registry, start_time) do
      # Get and prepare context (handles Step auto-chaining)
      raw_context = Keyword.get(opts, :context, %{})

      # Validate tool/data name conflicts
      validate_tool_data_conflict!(agent.tools, raw_context)

      case prepare_context(raw_context) do
        {:chained_failure, upstream_fail} ->
          # Short-circuit: upstream agent failed
          duration_ms = System.monotonic_time(:millisecond) - start_time

          step =
            PtcRunner.Step.error(
              :chained_failure,
              "Upstream agent failed: #{upstream_fail.reason}",
              %{},
              %{upstream: upstream_fail}
            )

          updated_step = %{step | usage: %{duration_ms: duration_ms, memory_bytes: 0}}
          {:error, updated_step}

        {context, received_field_descriptions} ->
          # Determine execution mode
          # JSON mode always uses the loop (even for single-shot) since it has its own simpler flow
          # PTC-Lisp single-shot (max_turns == 1, no tools) uses run_single_shot for efficiency
          if agent.output == :ptc_lisp and agent.max_turns == 1 and map_size(agent.tools) == 0 and
               agent.retry_turns == 0 do
            # PTC-Lisp single-shot mode
            run_single_shot(
              agent,
              llm,
              context,
              start_time,
              llm_registry,
              received_field_descriptions,
              opts
            )
          else
            # Loop mode (including JSON mode) - delegate to Loop.run/2
            # Update opts with prepared context and received field descriptions
            updated_opts =
              opts
              |> Keyword.put(:context, context)
              |> Keyword.put(:_received_field_descriptions, received_field_descriptions)

            alias PtcRunner.SubAgent.Loop
            Loop.run(agent, updated_opts)
          end
      end
    else
      error -> error
    end
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
      ** (PtcRunner.SubAgentError) SubAgent failed: failed - %{message: "Error", reason: :test}

  """
  @spec run!(t() | String.t(), keyword()) :: PtcRunner.Step.t()
  def run!(agent, opts \\ []) do
    case run(agent, opts) do
      {:ok, step} -> step
      {:error, step} -> raise PtcRunner.SubAgentError, %{step: step}
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

  defp validate_llm_presence(nil, start_time) do
    return_error(:llm_required, "llm option is required", %{}, start_time)
  end

  defp validate_llm_presence(_llm, _start_time), do: :ok

  defp validate_llm_registry(registry, start_time) when is_map(registry) do
    # Check that all registry values are function/1
    invalid_entries =
      Enum.reject(registry, fn {_key, value} -> is_function(value, 1) end)

    if invalid_entries == [] do
      :ok
    else
      {key, _value} = hd(invalid_entries)

      return_error(
        :invalid_llm_registry,
        "llm_registry values must be function/1. Invalid entry: #{inspect(key)}",
        %{},
        start_time
      )
    end
  end

  defp validate_llm_registry(_registry, start_time) do
    return_error(:invalid_llm_registry, "llm_registry must be a map", %{}, start_time)
  end

  # Validates that tool names don't conflict with context data keys.
  # Conflicts would cause undefined behavior in the tool/ and data/ namespaces.
  defp validate_tool_data_conflict!(tools, _raw_context) when map_size(tools) == 0 do
    # No tools, no conflict possible
    :ok
  end

  defp validate_tool_data_conflict!(tools, %PtcRunner.Step{} = step) do
    # Extract context map from Step
    context_map =
      case step do
        %{fail: fail} when fail != nil -> %{}
        %{return: return} when is_map(return) -> return
        _ -> %{}
      end

    validate_tool_data_conflict!(tools, context_map)
  end

  defp validate_tool_data_conflict!(tools, context) when is_map(context) do
    # Convert tool names to strings for comparison
    tool_names = Map.keys(tools) |> Enum.map(&to_string/1) |> MapSet.new()
    # Convert context keys to strings for comparison
    context_keys = Map.keys(context) |> Enum.map(&to_string/1) |> MapSet.new()

    conflicts = MapSet.intersection(tool_names, context_keys)

    if MapSet.size(conflicts) > 0 do
      conflict_name = conflicts |> MapSet.to_list() |> List.first()
      raise ArgumentError, "#{conflict_name} is both a tool and data - rename one"
    end

    :ok
  end

  defp validate_tool_data_conflict!(_tools, _context), do: :ok

  # Prepares context for execution, handling Step auto-chaining
  # Returns {:chained_failure, fail} | {context_map, field_descriptions | nil}
  defp prepare_context(%PtcRunner.Step{fail: fail} = _step) when fail != nil do
    {:chained_failure, fail}
  end

  defp prepare_context(
         %PtcRunner.Step{fail: nil, return: return, field_descriptions: descs} = _step
       )
       when is_map(return) do
    {return, descs}
  end

  defp prepare_context(%PtcRunner.Step{fail: nil, return: nil, field_descriptions: descs} = _step) do
    {%{}, descs}
  end

  defp prepare_context(%PtcRunner.Step{fail: nil, field_descriptions: descs} = _step) do
    # Non-map return value - can't use as context directly
    # This will be caught by template expansion or signature validation
    {%{}, descs}
  end

  defp prepare_context(context) when is_map(context), do: {context, nil}
  defp prepare_context(nil), do: {%{}, nil}

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

  # Single-shot execution: one LLM call, no tools, expression result returned
  defp run_single_shot(
         agent,
         llm,
         context,
         start_time,
         llm_registry,
         received_field_descriptions,
         opts
       ) do
    collect_messages = Keyword.get(opts, :collect_messages, false)

    # Expand template in mission
    expanded_prompt = expand_template(agent.prompt, context)

    # Build resolution context for language_spec callbacks
    messages = [%{role: :user, content: expanded_prompt}]

    resolution_context = %{
      turn: 1,
      model: llm,
      memory: %{},
      messages: messages
    }

    # Use SystemPrompt.generate for consistency with loop mode
    # Pass received field descriptions for rendering in prompt
    alias PtcRunner.SubAgent.SystemPrompt

    system_prompt =
      SystemPrompt.generate(agent,
        context: context,
        resolution_context: resolution_context,
        received_field_descriptions: received_field_descriptions
      )

    # Build LLM input
    llm_input = %{
      system: system_prompt,
      messages: [%{role: :user, content: expanded_prompt}]
    }

    # Call LLM
    alias PtcRunner.SubAgent.LLMResolver

    case LLMResolver.resolve(llm, llm_input, llm_registry) do
      {:ok, %{content: content, tokens: tokens}} ->
        # Extract code from response content
        case extract_code(content) do
          {:ok, code} ->
            # Execute via Lisp
            lisp_result =
              case PtcRunner.Lisp.run(code,
                     context: context,
                     tools: %{},
                     float_precision: agent.float_precision
                   ) do
                {:ok, step} -> unwrap_sentinels(step)
                other -> other
              end

            # Add usage metrics, field_descriptions, and trace from this execution
            case lisp_result do
              {:ok, step} ->
                duration_ms = System.monotonic_time(:millisecond) - start_time

                trace =
                  build_single_shot_trace(
                    agent,
                    system_prompt,
                    llm_input,
                    content,
                    code,
                    {:ok, step},
                    opts
                  )

                collected_messages =
                  build_single_shot_messages(
                    collect_messages,
                    system_prompt,
                    expanded_prompt,
                    content
                  )

                # Normalize return value keys (hyphen -> underscore at boundary)
                normalized_step = %{step | return: KeyNormalizer.normalize_keys(step.return)}

                updated_step =
                  normalized_step
                  |> update_step_usage(duration_ms, tokens)
                  |> Map.put(:field_descriptions, agent.field_descriptions)
                  |> Map.put(:turns, trace)
                  |> Map.put(:messages, collected_messages)

                {:ok, updated_step}

              {:error, step} ->
                duration_ms = System.monotonic_time(:millisecond) - start_time

                trace =
                  build_single_shot_trace(
                    agent,
                    system_prompt,
                    llm_input,
                    content,
                    code,
                    {:error, step},
                    opts
                  )

                collected_messages =
                  build_single_shot_messages(
                    collect_messages,
                    system_prompt,
                    expanded_prompt,
                    content
                  )

                updated_step =
                  step
                  |> update_step_usage(duration_ms, tokens)
                  |> Map.put(:turns, trace)
                  |> Map.put(:messages, collected_messages)

                {:error, updated_step}
            end

          :none ->
            return_error(
              :no_code_found,
              "No PTC-Lisp code found in LLM response",
              %{},
              start_time
            )
        end

      {:error, reason} ->
        return_error(:llm_error, "LLM call failed: #{inspect(reason)}", %{}, start_time)
    end
  end

  # Expand template placeholders with context values
  defp expand_template(prompt, context) when is_map(context) do
    alias PtcRunner.SubAgent.PromptExpander
    {:ok, result} = PromptExpander.expand(prompt, context, on_missing: :keep)
    result
  end

  # Extract PTC-Lisp code from LLM response
  defp extract_code(text) do
    # Try extracting from markdown code block (lisp, clojure, or unmarked)
    case Regex.run(~r/```(?:lisp|clojure)?\s*([\s\S]+?)\s*```/, text) do
      [_, content] ->
        {:ok, String.trim(content)}

      nil ->
        # Try finding a bare S-expression (starts with paren)
        # Match expressions like (+ 40 2) or more complex ones
        trimmed = String.trim(text)

        if String.starts_with?(trimmed, "(") do
          {:ok, trimmed}
        else
          :none
        end
    end
  end

  # Helper to create error Step
  defp return_error(reason, message, memory, start_time) do
    duration_ms = System.monotonic_time(:millisecond) - start_time

    step = PtcRunner.Step.error(reason, message, memory)

    updated_step = %{step | usage: %{duration_ms: duration_ms, memory_bytes: 0}}

    {:error, updated_step}
  end

  # Update step with usage metrics (for single-shot mode)
  defp update_step_usage(step, duration_ms, tokens) do
    usage = step.usage || %{memory_bytes: 0}
    base_usage = Map.put(usage, :duration_ms, duration_ms)

    # Add token counts if available
    usage_with_tokens =
      case tokens do
        %{input: input, output: output} ->
          Map.merge(base_usage, %{
            input_tokens: input,
            output_tokens: output,
            total_tokens: LLMResolver.total_tokens(tokens),
            llm_requests: 1
          })

        _ ->
          base_usage
      end

    %{step | usage: usage_with_tokens}
  end

  # Build collected messages for single-shot mode (or nil if not collecting)
  defp build_single_shot_messages(false, _system_prompt, _user_prompt, _assistant_content),
    do: nil

  defp build_single_shot_messages(true, system_prompt, user_prompt, assistant_content) do
    [
      %{role: :system, content: system_prompt},
      %{role: :user, content: user_prompt},
      %{role: :assistant, content: assistant_content}
    ]
  end

  # Helper to build trace for single-shot execution
  defp build_single_shot_trace(
         _agent,
         system_prompt,
         llm_input,
         response,
         code,
         lisp_result,
         opts
       ) do
    alias PtcRunner.SubAgent.Loop.Metrics

    trace_mode = Keyword.get(opts, :trace, true)
    debug = Keyword.get(opts, :debug, false)

    state = %{
      turn: 1,
      debug: debug,
      trace_mode: trace_mode,
      context: lisp_result |> elem(1) |> Map.get(:context, %{}),
      memory: %{},
      # Metrics.build_turn looks for :current_messages, not :messages
      current_messages: llm_input.messages,
      current_system_prompt: system_prompt
    }

    {status, lisp_step} = lisp_result

    turn =
      Metrics.build_turn(
        state,
        response,
        code,
        lisp_step.return || lisp_step.fail,
        success?: status == :ok,
        prints: lisp_step.prints,
        tool_calls: lisp_step.tool_calls,
        memory: lisp_step.memory
      )

    Metrics.apply_trace_filter([turn], trace_mode, status == :error)
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
  def as_tool(%__MODULE__{} = agent, opts \\ []) do
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

  @doc """
  Unwraps internal sentinel values from a search result.

  Handles:
  - `{:__ptc_return__, value}` -> `{:ok, step_with_raw_value}`
  - `{:__ptc_fail__, value}` -> `{:error, error_step}`

  Used by single-shot mode and compiled agents to provide clean results.
  """
  @spec unwrap_sentinels(PtcRunner.Step.t()) ::
          {:ok, PtcRunner.Step.t()} | {:error, PtcRunner.Step.t()}
  def unwrap_sentinels(%{return: {:__ptc_return__, value}} = step) do
    {:ok, %{step | return: value}}
  end

  def unwrap_sentinels(%{return: {:__ptc_fail__, value}} = step) do
    # Handle both structured and simple fail values
    {reason, message} =
      if is_map(value) do
        {Map.get(value, :reason, :failed), Map.get(value, :message, inspect(value))}
      else
        {:failed, inspect(value)}
      end

    # Convert to error step to preserve failure intent
    {:error, %{step | return: nil, fail: %{reason: reason, message: message}}}
  end

  def unwrap_sentinels(step), do: {:ok, step}

  @doc "See `PtcRunner.SubAgent.Compiler.compile/2`."
  defdelegate compile(agent, opts), to: PtcRunner.SubAgent.Compiler

  @doc """
  Preview the system and user prompts that would be sent to the LLM.

  This function generates and returns the prompts without executing the agent,
  useful for debugging prompt generation, verifying template expansion, and
  reviewing what the LLM will see.

  ## Parameters

  - `agent` - A `%SubAgent{}` struct
  - `opts` - Keyword list with:
    - `context` - Context map for template expansion (default: %{})

  ## Returns

  A map with:
  - `:system` - The static system prompt (cacheable - does NOT include mission)
  - `:user` - The full first user message (context sections + mission)
  - `:tool_schemas` - List of tool schema maps with name, signature, and description fields
  - `:schema` - JSON schema for the return type (JSON mode only, nil for PTC-Lisp)

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(
      ...>   prompt: "Find emails for {{user}}",
      ...>   signature: "(user :string) -> {count :int}",
      ...>   tools: %{"list_emails" => fn _ -> [] end}
      ...> )
      iex> preview = PtcRunner.SubAgent.preview_prompt(agent, context: %{user: "alice"})
      iex> preview.user =~ "Find emails for alice"
      true
      iex> preview.user =~ "# Mission"
      true
      iex> preview.system =~ "PTC-Lisp"
      true
      iex> preview.system =~ "# Mission"
      false

  """
  @spec preview_prompt(t(), keyword()) :: %{
          system: String.t(),
          user: String.t(),
          tool_schemas: [map()],
          schema: map() | nil
        }

  def preview_prompt(%__MODULE__{} = agent, opts \\ []) do
    alias PtcRunner.SubAgent.Loop.JsonMode

    context = Keyword.get(opts, :context, %{})

    # Use JSON mode preview for JSON output agents
    if agent.output == :json do
      preview = JsonMode.preview_prompt(agent, context)
      Map.put(preview, :tool_schemas, [])
    else
      preview_prompt_ptc_lisp(agent, context)
    end
  end

  # PTC-Lisp mode preview (original implementation)
  defp preview_prompt_ptc_lisp(agent, context) do
    alias PtcRunner.SubAgent.{PromptExpander, SystemPrompt}

    # Resolve :self tools before generating prompts so the context includes proper signatures
    resolved_tools = resolve_self_tools(agent.tools, agent)
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
      [context_prompt, "# Mission\n\n#{expanded_mission}"]
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

  # Resolve :self sentinels in tools map to SubAgentTool structs
  defp resolve_self_tools(tools, agent) do
    alias PtcRunner.SubAgent.SubAgentTool

    Map.new(tools, fn
      {name, :self} ->
        {name,
         %SubAgentTool{
           agent: agent,
           bound_llm: nil,
           signature: agent.signature,
           description:
             agent.description || "Recursively invoke this agent on a subset of the input"
         }}

      other ->
        other
    end)
  end

  # Auto-inject trace_context if TraceLog is active and trace_context not already provided.
  # This enables automatic trace propagation to nested agents when running inside
  # TraceLog.with_trace/2 without requiring explicit trace_context option.
  defp maybe_inject_trace_context(opts) do
    if Keyword.has_key?(opts, :trace_context) do
      # trace_context already provided (e.g., from ToolNormalizer for child agents)
      opts
    else
      # Check if TraceLog is active in this process
      case PtcRunner.TraceLog.current_collector() do
        nil ->
          opts

        collector ->
          # Get trace_id and path from the collector, build initial trace_context
          trace_id = Collector.trace_id(collector)
          trace_path = Collector.path(collector)
          parent_span_id = Telemetry.current_span_id()

          trace_context = %{
            trace_id: trace_id,
            parent_span_id: parent_span_id,
            depth: 0,
            trace_dir: Path.dirname(trace_path)
          }

          Keyword.put(opts, :trace_context, trace_context)
      end
    end
  end
end
