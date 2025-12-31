defmodule PtcRunner.SubAgent.Prompt do
  @moduledoc """
  System prompt generation for SubAgent LLM interactions.

  Generates comprehensive system prompts that provide the LLM with:
  - Role and purpose definition
  - Environment rules and constraints
  - Data inventory from context
  - Tool schemas and documentation
  - PTC-Lisp language reference
  - Output format requirements

  See [system-prompt-template.md](https://github.com/andreasronge/ptc_runner/blob/main/docs/ptc_agents/system-prompt-template.md)
  for the full specification.

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "Add {{x}} and {{y}}")
      iex> context = %{x: 5, y: 3}
      iex> prompt = PtcRunner.SubAgent.Prompt.generate(agent, context: context)
      iex> prompt =~ "You are a PTC-Lisp program generator"
      true
      iex> prompt =~ "ctx/x"
      true

  """

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Signature
  alias PtcRunner.SubAgent.Signature.Renderer
  alias PtcRunner.SubAgent.Template

  @language_reference """
  # PTC-Lisp Quick Reference

  ## Syntax
  - Clojure-inspired syntax
  - Keywords: `:keyword`
  - Maps: `{:key value :key2 value2}`
  - Vectors: `[1 2 3]`
  - Function calls: `(function arg1 arg2)`

  ## Core Functions
  - `call` - Invoke tools: `(call "tool-name" {:arg value})`
  - `let` - Local bindings: `(let [x 1 y 2] (+ x y))`
  - `if` - Conditional: `(if condition then-expr else-expr)`
  - `do` - Sequential: `(do expr1 expr2 expr3)`
  - `fn` - Anonymous function: `(fn [x] (* x 2))`

  ## Context Access
  - `ctx/key` - Read from context
  - `memory/key` - Read from persistent memory
  - `(memory/put :key value)` - Store in memory

  ## Collections
  - `map`, `mapv` - Transform: `(mapv :id items)`
  - `filter` - Filter: `(filter #(> (:score %) 0.5) items)`
  - `reduce` - Fold: `(reduce + 0 numbers)`
  - `first`, `last`, `nth` - Access elements
  - `count`, `empty?` - Collection info

  ## Common Patterns
  ```clojure
  ;; Fetch and process
  (let [users (call "get_users" {:limit 10})]
    (mapv :name users))

  ;; Conditional logic
  (if (empty? results)
    (call "fail" {:reason :not_found :message "No results"})
    (call "return" {:count (count results)}))

  ;; Multi-step with memory
  (do
    (memory/put :step1 (call "search" {:q "test"}))
    (call "process" {:data memory/step1}))
  ```
  """

  @output_format """
  # Output Format

  Respond with a single ```clojure code block containing your program:

  ```clojure
  (let [data (call "fetch" {:id ctx/user_id})]
    (call "return" {:result data}))
  ```

  Do NOT include:
  - Explanatory text before or after the code
  - Multiple code blocks
  - Code outside of the ```clojure block
  """

  @doc """
  Generate a complete system prompt for a SubAgent.

  ## Parameters

  - `agent` - A `%SubAgent{}` struct
  - `opts` - Keyword list with:
    - `context` - Context map for data inventory (default: %{})
    - `error_context` - Optional error from previous turn for recovery prompts

  ## Returns

  A string containing the complete system prompt with all sections.

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "Process data")
      iex> prompt = PtcRunner.SubAgent.Prompt.generate(agent, context: %{user: "Alice"})
      iex> prompt =~ "# Role"
      true
      iex> prompt =~ "# Rules"
      true

  """
  @spec generate(SubAgent.t(), keyword()) :: String.t()
  def generate(%SubAgent{} = agent, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    error_context = Keyword.get(opts, :error_context)

    # Generate base prompt
    base_prompt = generate_base_prompt(agent, context)

    # Add error recovery prompt if needed
    base_prompt_with_error =
      if error_context do
        base_prompt <> "\n\n" <> generate_error_recovery_prompt(error_context)
      else
        base_prompt
      end

    # Apply customization
    customized_prompt = apply_customization(base_prompt_with_error, agent.system_prompt)

    # Apply truncation if prompt_limit is set
    truncate_if_needed(customized_prompt, agent.prompt_limit)
  end

  defp generate_base_prompt(%SubAgent{} = agent, context) do
    # Parse signature if present
    context_signature =
      case agent.signature do
        nil -> nil
        sig_str -> Signature.parse(sig_str) |> elem(1)
      end

    # Get custom sections from system_prompt if it's a map
    {language_ref, output_fmt} =
      case agent.system_prompt do
        opts when is_map(opts) ->
          {
            Map.get(opts, :language_spec, @language_reference),
            Map.get(opts, :output_format, @output_format)
          }

        _ ->
          {@language_reference, @output_format}
      end

    # Generate sections
    role_section = generate_role_section()
    rules_section = generate_rules_section()
    data_inventory = generate_data_inventory(context, context_signature)
    tool_schemas = generate_tool_schemas(agent.tools)
    mission = expand_mission(agent.prompt, context)

    # Combine all sections
    [
      role_section,
      rules_section,
      data_inventory,
      tool_schemas,
      language_ref,
      output_fmt,
      "# Mission\n\n#{mission}"
    ]
    |> Enum.join("\n\n")
  end

  @doc """
  Generate the data inventory section from context.

  Shows available context variables with their inferred types and sample values.
  Handles nested maps, lists, and firewalled fields (prefixed with `_`).

  ## Parameters

  - `context` - Context map
  - `context_signature` - Optional parsed signature for type information

  ## Returns

  A string containing the data inventory section in markdown format.

  ## Examples

      iex> context = %{user_id: 123, name: "Alice"}
      iex> inventory = PtcRunner.SubAgent.Prompt.generate_data_inventory(context, nil)
      iex> inventory =~ "ctx/user_id"
      true
      iex> inventory =~ "ctx/name"
      true

  """
  @spec generate_data_inventory(map(), Signature.signature() | nil) :: String.t()
  def generate_data_inventory(context, context_signature \\ nil)

  def generate_data_inventory(context, _context_signature) when map_size(context) == 0 do
    """
    # Data Inventory

    No data available in context.
    """
  end

  def generate_data_inventory(context, context_signature) do
    # Get parameter types from signature if available
    param_types =
      case context_signature do
        {:signature, params, _return_type} ->
          Map.new(params)

        _ ->
          %{}
      end

    rows =
      context
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join("\n", fn {key, value} ->
        key_str = to_string(key)
        type_str = format_type(key_str, value, param_types)
        is_firewalled = String.starts_with?(key_str, "_")
        sample = if is_firewalled, do: "[Hidden]", else: format_sample(value)
        firewalled_note = if is_firewalled, do: " [Firewalled]", else: ""

        "| `ctx/#{key_str}` | `#{type_str}` | #{sample}#{firewalled_note} |"
      end)

    header = """
    # Data Inventory

    Available in `ctx/`:

    | Key | Type | Sample |
    |-----|------|--------|
    """

    note =
      if Enum.any?(context, fn {k, _v} -> String.starts_with?(to_string(k), "_") end) do
        "\n\nNote: Firewalled fields (prefixed with `_`) are available in your program but hidden from conversation history."
      else
        ""
      end

    header <> rows <> note
  end

  @doc """
  Generate the tool schemas section.

  Shows all available tools with their signatures and descriptions.

  ## Parameters

  - `tools` - Map of tool name to function

  ## Returns

  A string containing the tool schemas section.

  ## Examples

      iex> tools = %{"add" => fn %{x: x, y: y} -> x + y end}
      iex> schemas = PtcRunner.SubAgent.Prompt.generate_tool_schemas(tools)
      iex> schemas =~ "# Available Tools"
      true

  """
  @spec generate_tool_schemas(map()) :: String.t()
  def generate_tool_schemas(tools) when map_size(tools) == 0 do
    # Even with no user tools, show return/fail
    """
    # Available Tools

    ## Tools you can call

    #{format_tool("return")}

    #{format_tool("fail")}
    """
  end

  def generate_tool_schemas(tools) do
    # Always include return and fail tools in the documentation
    tool_docs =
      tools
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map_join("\n\n", fn name -> format_tool(name) end)

    # Add standard return/fail tools if not already present
    standard_tools =
      [
        unless Map.has_key?(tools, "return") do
          format_tool("return")
        end,
        unless Map.has_key?(tools, "fail") do
          format_tool("fail")
        end
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join("\n\n", & &1)

    tools_section =
      if tool_docs == "" do
        standard_tools
      else
        tool_docs <>
          if standard_tools != "", do: "\n\n" <> standard_tools, else: ""
      end

    """
    # Available Tools

    ## Tools you can call

    #{tools_section}
    """
  end

  @doc """
  Apply system prompt customization.

  Handles three forms:
  - String: complete override
  - Function: transformer that receives and modifies the prompt
  - Map: selective section replacements and prefix/suffix

  ## Parameters

  - `base_prompt` - The generated base prompt
  - `customization` - nil | String.t() | (String.t() -> String.t()) | map()

  ## Returns

  The customized prompt string.

  ## Examples

      iex> base = "# Role\\n\\nYou are a generator."
      iex> PtcRunner.SubAgent.Prompt.apply_customization(base, nil)
      "# Role\\n\\nYou are a generator."

      iex> base = "# Role\\n\\nYou are a generator."
      iex> PtcRunner.SubAgent.Prompt.apply_customization(base, "Custom prompt")
      "Custom prompt"

      iex> base = "# Role\\n\\nYou are a generator."
      iex> transformer = fn prompt -> "PREFIX\\n\\n" <> prompt end
      iex> PtcRunner.SubAgent.Prompt.apply_customization(base, transformer)
      "PREFIX\\n\\n# Role\\n\\nYou are a generator."

  """
  @spec apply_customization(String.t(), SubAgent.system_prompt_opts() | nil) :: String.t()
  def apply_customization(base_prompt, nil), do: base_prompt

  # String override - use as-is
  def apply_customization(_base_prompt, override) when is_binary(override), do: override

  # Function transformer
  def apply_customization(base_prompt, transformer) when is_function(transformer, 1) do
    transformer.(base_prompt)
  end

  # Map customization - prefix and suffix (language_spec/output_format already applied)
  def apply_customization(base_prompt, opts) when is_map(opts) do
    # Apply prefix and suffix
    prefix = Map.get(opts, :prefix, "")
    suffix = Map.get(opts, :suffix, "")

    [prefix, base_prompt, suffix]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Generate error recovery prompt for parse failures.

  Shows the error and provides guidance to help the LLM fix the issue.

  ## Parameters

  - `error_context` - Map with error details (e.g., %{type: :parse_error, message: "..."})

  ## Returns

  A string with error recovery guidance.

  ## Examples

      iex> error = %{type: :parse_error, message: "Unexpected token at position 45"}
      iex> recovery = PtcRunner.SubAgent.Prompt.generate_error_recovery_prompt(error)
      iex> recovery =~ "Previous Turn Error"
      true
      iex> recovery =~ "Unexpected token"
      true

  """
  @spec generate_error_recovery_prompt(map()) :: String.t()
  def generate_error_recovery_prompt(error_context) do
    error_type = Map.get(error_context, :type, :unknown_error)
    error_message = Map.get(error_context, :message, "Unknown error")

    """
    # Previous Turn Error

    Your previous program failed with:
    - **Error**: #{error_type}
    - **Message**: #{error_message}

    Please ensure your response:
    1. Contains a ```clojure code block
    2. Uses valid s-expression syntax
    3. Calls tools with (call "tool-name" {...})

    Please fix the issue and try again.
    """
  end

  @doc """
  Truncate prompt if it exceeds the configured character limit.

  Uses character count as an approximation for tokens (roughly 4 chars per token).
  Preserves critical sections and truncates data/tools first.

  ## Parameters

  - `prompt` - The full prompt string
  - `limit_config` - nil or map with :max_chars

  ## Returns

  The prompt, possibly truncated with a warning if limit was exceeded.

  ## Examples

      iex> short_prompt = "# Role\\n\\nShort prompt"
      iex> PtcRunner.SubAgent.Prompt.truncate_if_needed(short_prompt, nil)
      "# Role\\n\\nShort prompt"

      iex> long_prompt = String.duplicate("x", 1000)
      iex> result = PtcRunner.SubAgent.Prompt.truncate_if_needed(long_prompt, %{max_chars: 100})
      iex> String.length(result) < String.length(long_prompt)
      true
      iex> result =~ "truncated"
      true

  """
  @spec truncate_if_needed(String.t(), map() | nil) :: String.t()
  def truncate_if_needed(prompt, nil), do: prompt

  def truncate_if_needed(prompt, limit_config) when is_map(limit_config) do
    max_chars = Map.get(limit_config, :max_chars)

    if max_chars && String.length(prompt) > max_chars do
      require Logger

      Logger.warning(
        "System prompt exceeds limit (#{String.length(prompt)} > #{max_chars} chars), truncating"
      )

      # Simple truncation strategy: keep first part, add warning
      truncated = String.slice(prompt, 0, max_chars)

      truncated <>
        "\n\n[... truncated due to length limit ...]\n\nNote: Some content was removed to fit within the character limit."
    else
      prompt
    end
  end

  # ============================================================
  # Private Helpers
  # ============================================================

  defp generate_role_section do
    """
    # Role

    You are a PTC-Lisp program generator. Your task is to write programs that accomplish
    the user's mission by calling tools and processing data.

    You MUST respond with a single PTC-Lisp program in a ```clojure code block.
    The program will be executed, and you may see results in subsequent turns.

    Your mission ends ONLY when you call the `return` or `fail` tool.
    """
  end

  defp generate_rules_section do
    """
    # Rules

    1. Respond with EXACTLY ONE ```clojure code block
    2. Do not include explanatory text outside the code block
    3. Use `(call "tool-name" args)` to invoke tools
    4. Use `ctx/key` to access context data
    5. Use `memory/key` or `(memory/get :key)` for persistent state
    6. Call `(call "return" result)` when the mission is complete
    7. Call `(call "fail" {:reason :keyword :message "..."})` on unrecoverable errors
    """
  end

  defp expand_mission(prompt, context) do
    case Template.expand(prompt, context) do
      {:ok, expanded} -> expanded
      {:error, {:missing_keys, _keys}} -> prompt
    end
  end

  defp format_type(key_str, value, param_types) do
    # Try to get type from signature first
    case Map.get(param_types, key_str) do
      nil ->
        # Infer type from value
        infer_type(value)
        |> Renderer.render_type()

      type ->
        Renderer.render_type(type)
    end
  end

  # Infer type from runtime value
  defp infer_type(value) when is_binary(value), do: :string
  defp infer_type(value) when is_integer(value), do: :int
  defp infer_type(value) when is_float(value), do: :float
  defp infer_type(value) when is_boolean(value), do: :bool
  defp infer_type(value) when is_atom(value), do: :keyword

  defp infer_type(value) when is_list(value) do
    case value do
      [] -> {:list, :any}
      [first | _] -> {:list, infer_type(first)}
    end
  end

  defp infer_type(value) when is_map(value) do
    if map_size(value) == 0 do
      :map
    else
      # Infer map fields
      fields =
        value
        |> Enum.take(5)
        |> Enum.map(fn {k, v} -> {to_string(k), infer_type(v)} end)

      {:map, fields}
    end
  end

  defp infer_type(_value), do: :any

  defp format_sample(value) when is_binary(value) do
    if String.length(value) > 50 do
      "\"#{String.slice(value, 0, 47)}...\""
    else
      inspect(value)
    end
  end

  defp format_sample(value) when is_list(value) do
    cond do
      value == [] ->
        "[]"

      length(value) <= 3 ->
        inspect(value)

      true ->
        sample = Enum.take(value, 3)
        inspect(sample) <> " (#{length(value)} items)"
    end
  end

  defp format_sample(value) when is_map(value) do
    if map_size(value) == 0 do
      "{}"
    else
      # Show first few keys
      keys =
        value
        |> Map.keys()
        |> Enum.take(3)
        |> Enum.map_join(", ", &to_string/1)

      if map_size(value) > 3 do
        "{#{keys}, ...}"
      else
        "{#{keys}}"
      end
    end
  end

  defp format_sample(value), do: inspect(value)

  defp format_tool("return") do
    """
    ### return
    ```
    return(data :any) -> :exit-success
    ```
    Complete the mission successfully. Data must match your mission's signature.
    """
  end

  defp format_tool("fail") do
    """
    ### fail
    ```
    fail(error {:reason :keyword, :message :string, :op :string?, :details :map?}) -> :exit-error
    ```
    Terminate with an error. Use when the mission cannot be completed.
    """
  end

  defp format_tool(name) do
    # For user-defined tools, show basic signature
    """
    ### #{name}
    ```
    #{name}(args :map) -> :any
    ```
    User-defined tool. Check implementation for details.
    """
  end
end
