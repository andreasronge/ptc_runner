defmodule PtcRunner.SubAgent.Prompt do
  @moduledoc """
  System prompt generation for SubAgent LLM interactions.

  Orchestrates prompt generation by combining sections from sub-modules:
  - `Prompt.DataInventory` - Context variables with types and samples
  - `Prompt.Tools` - Available tool schemas and signatures
  - `Prompt.Output` - Expected return format from signature

  ## Customization

  The `system_prompt` field on `SubAgent` accepts:
  - **Map** - `:prefix`, `:suffix`, `:language_spec`, `:output_format`
  - **Function** - `fn default_prompt -> modified_prompt end`
  - **String** - Complete override

  ## Language Spec

  The `:language_spec` option can be:
  - **Atom** - Resolved via `PtcRunner.Lisp.Prompts.get!/1`
  - **String** - Used as-is
  - **Callback** - `fn ctx -> "prompt" end`

  Default: `:single_shot` for `max_turns: 1`, `:multi_turn` otherwise.

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "Add {{x}} and {{y}}")
      iex> context = %{x: 5, y: 3}
      iex> prompt = PtcRunner.SubAgent.Prompt.generate(agent, context: context)
      iex> prompt =~ "You are a PTC-Lisp program generator"
      true
      iex> prompt =~ "ctx/x"
      true

  """

  require Logger

  alias PtcRunner.Lisp.Prompts
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Prompt.DataInventory
  alias PtcRunner.SubAgent.Prompt.Output
  alias PtcRunner.SubAgent.Prompt.Tools
  alias PtcRunner.SubAgent.Signature
  alias PtcRunner.SubAgent.Template

  @output_format """
  # Output Format

  Respond with a single ```clojure code block containing your program:

  ```clojure
  (let [data (ctx/fetch {:id ctx/user_id})]
    (return {:result data}))
  ```

  Do NOT include:
  - Explanatory text before or after the code
  - Multiple code blocks
  - Code outside of the ```clojure block
  """

  @doc """
  Generate a complete system prompt for a SubAgent.

  Options: `context` (map), `error_context` (map for recovery prompts).

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "Process data")
      iex> prompt = PtcRunner.SubAgent.Prompt.generate(agent, context: %{user: "Alice"})
      iex> prompt =~ "# Role" and prompt =~ "# Rules"
      true

  """
  @spec generate(SubAgent.t(), keyword()) :: String.t()
  def generate(%SubAgent{} = agent, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    error_context = Keyword.get(opts, :error_context)
    resolution_context = Keyword.get(opts, :resolution_context, %{})
    # Field descriptions received from upstream agent in a chain
    received_field_descriptions = Keyword.get(opts, :received_field_descriptions)

    # Generate base prompt with resolution context for language_spec callbacks
    base_prompt =
      generate_base_prompt(agent, context, resolution_context, received_field_descriptions)

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

  @doc """
  Resolve a language_spec value to a string.

  ## Examples

      iex> PtcRunner.SubAgent.Prompt.resolve_language_spec("custom prompt", %{})
      "custom prompt"

      iex> spec = PtcRunner.SubAgent.Prompt.resolve_language_spec(:single_shot, %{})
      iex> is_binary(spec) and String.contains?(spec, "PTC-Lisp")
      true

      iex> callback = fn ctx -> if ctx.turn > 1, do: "multi", else: "single" end
      iex> PtcRunner.SubAgent.Prompt.resolve_language_spec(callback, %{turn: 1})
      "single"

  """
  @spec resolve_language_spec(String.t() | atom() | (map() -> String.t()), map()) :: String.t()
  def resolve_language_spec(spec, context)

  def resolve_language_spec(spec, _context) when is_binary(spec), do: spec

  def resolve_language_spec(spec, _context) when is_atom(spec) do
    Prompts.get!(spec)
  end

  def resolve_language_spec(spec, context) when is_function(spec, 1) do
    spec.(context)
  end

  # Delegation to sub-modules for backward compatibility
  defdelegate generate_data_inventory(
                context,
                context_signature \\ nil,
                field_descriptions \\ nil
              ),
              to: DataInventory,
              as: :generate

  defdelegate generate_tool_schemas(tools, tool_catalog \\ nil), to: Tools, as: :generate

  @doc """
  Apply system prompt customization (string override, function, or map with prefix/suffix).

  ## Examples

      iex> PtcRunner.SubAgent.Prompt.apply_customization("base", nil)
      "base"

      iex> PtcRunner.SubAgent.Prompt.apply_customization("base", "override")
      "override"

      iex> PtcRunner.SubAgent.Prompt.apply_customization("base", fn p -> "PREFIX\\n" <> p end)
      "PREFIX\\nbase"

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

  ## Examples

      iex> error = %{type: :parse_error, message: "Unexpected token"}
      iex> PtcRunner.SubAgent.Prompt.generate_error_recovery_prompt(error) =~ "Previous Turn Error"
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
    3. Calls tools with (ctx/tool-name args)

    Please fix the issue and try again.
    """
  end

  @doc """
  Truncate prompt if it exceeds the configured character limit.

  ## Examples

      iex> PtcRunner.SubAgent.Prompt.truncate_if_needed("short", nil)
      "short"

      iex> result = PtcRunner.SubAgent.Prompt.truncate_if_needed(String.duplicate("x", 1000), %{max_chars: 100})
      iex> result =~ "truncated"
      true

  """
  @spec truncate_if_needed(String.t(), map() | nil) :: String.t()
  def truncate_if_needed(prompt, nil), do: prompt

  def truncate_if_needed(prompt, limit_config) when is_map(limit_config) do
    max_chars = Map.get(limit_config, :max_chars)

    if max_chars && String.length(prompt) > max_chars do
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

  defp generate_base_prompt(
         %SubAgent{} = agent,
         context,
         resolution_context,
         received_field_descriptions
       ) do
    # Parse signature if present
    context_signature =
      case agent.signature do
        nil ->
          nil

        sig_str ->
          case Signature.parse(sig_str) do
            {:ok, sig} -> sig
            {:error, _reason} -> nil
          end
      end

    # Get custom sections from system_prompt if it's a map
    # Default language_spec: :multi_turn for loop mode, :single_shot for single-shot
    default_spec = if agent.max_turns > 1, do: :multi_turn, else: :single_shot

    {language_ref, output_fmt} =
      case agent.system_prompt do
        opts when is_map(opts) ->
          # Resolve language_spec (can be string, atom, or callback)
          raw_spec = Map.get(opts, :language_spec, default_spec)
          resolved_spec = resolve_language_spec(raw_spec, resolution_context)

          {
            resolved_spec,
            Map.get(opts, :output_format, @output_format)
          }

        _ ->
          {Prompts.get(default_spec), @output_format}
      end

    # Generate sections
    role_section = generate_role_section()
    rules_section = generate_rules_section()
    # Pass received field descriptions for rendering in the data inventory
    data_inventory =
      DataInventory.generate(context, context_signature, received_field_descriptions)

    tool_schemas = Tools.generate(agent.tools, agent.tool_catalog)

    expected_output = Output.generate(context_signature, agent.field_descriptions)

    mission = expand_mission(agent.prompt, context)

    # Combine all sections
    [
      role_section,
      rules_section,
      data_inventory,
      tool_schemas,
      language_ref,
      expected_output,
      output_fmt,
      "# Mission\n\n#{mission}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

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
    3. Use `(ctx/tool-name args)` to invoke tools
    4. Use `ctx/key` to access context data
    5. Access stored values as plain symbols (values from previous turns)
    6. Call `(return result)` when the mission is complete
    7. Call `(fail {:reason :keyword :message "..."})` on unrecoverable errors
    """
  end

  defp expand_mission(prompt, context) do
    case Template.expand(prompt, context) do
      {:ok, expanded} -> expanded
      {:error, {:missing_keys, _keys}} -> prompt
    end
  end
end
