defmodule PtcRunner.SubAgent.SystemPrompt do
  @moduledoc """
  System prompt generation for SubAgent LLM interactions.

  Orchestrates prompt generation by combining sections from:
  - `Namespace` modules - Compact Lisp-style format for tools and data
  - `SystemPrompt.Output` - Expected return format from signature

  ## Prompt Caching Architecture

  To enable efficient prompt caching (e.g., Anthropic's cache_control), the prompt
  is split into **static** and **dynamic** sections:

  - **Static (system prompt)**: `generate_system/2` returns language reference and output
    format - these rarely change and benefit from caching across different questions.
  - **Dynamic (user message)**: `generate_context/2` returns data inventory, tool schemas,
    and expected output - these vary per agent configuration but not per question.

  The mission is placed only in the user message (not duplicated in system prompt).

  ## Customization

  The `system_prompt` field on `SubAgent` accepts:
  - **Map** - `:prefix`, `:suffix`, `:language_spec`, `:output_format`
  - **Function** - `fn default_prompt -> modified_prompt end`
  - **String** - Complete override

  ## Language Spec

  The `:language_spec` option can be:
  - **Atom** - Resolved via `PtcRunner.Lisp.LanguageSpec.get!/1`
  - **String** - Used as-is
  - **Callback** - `fn ctx -> "prompt" end`

  Default: `:single_shot` for `max_turns: 1`, `:multi_turn` otherwise.

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "Add {{x}} and {{y}}")
      iex> context = %{x: 5, y: 3}
      iex> prompt = PtcRunner.SubAgent.SystemPrompt.generate(agent, context: context)
      iex> prompt =~ "## Role"
      true
      iex> prompt =~ "data/x"
      true

  """

  require Logger

  alias PtcRunner.Lisp.LanguageSpec
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Namespace
  alias PtcRunner.SubAgent.PromptExpander
  alias PtcRunner.SubAgent.Signature
  alias PtcRunner.SubAgent.SystemPrompt.Output

  @output_format """
  # Output Format

  For complex tasks, think through the problem first, then respond with EXACTLY ONE ```clojure code block:

  thinking:
  [your reasoning here]

  ```clojure
  (your-program-here)
  ```

  Do NOT include multiple code blocks or code outside the ```clojure block.
  """

  @doc """
  Generate a complete system prompt for a SubAgent.

  Options: `context` (map), `error_context` (map for recovery prompts).

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "Process data")
      iex> prompt = PtcRunner.SubAgent.SystemPrompt.generate(agent, context: %{user: "Alice"})
      iex> prompt =~ "## Role" and prompt =~ "thinking:"
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
  Generate static system prompt sections (cacheable).

  Returns only the language reference and output format - these sections rarely
  change across different questions and benefit from prompt caching.

  This function has an alias `generate_static/2` for semantic clarity.

  ## Options

  - `:resolution_context` - Map with turn/model/memory/messages for language_spec callbacks

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "Test")
      iex> system = PtcRunner.SubAgent.SystemPrompt.generate_system(agent)
      iex> system =~ "## Role" and system =~ "# Output Format"
      true
      iex> system =~ "# Data Inventory"
      false

  """
  @spec generate_system(SubAgent.t(), keyword()) :: String.t()
  def generate_system(%SubAgent{} = agent, opts \\ []) do
    resolution_context = Keyword.get(opts, :resolution_context, %{})

    {language_ref, output_fmt} = resolve_static_sections(agent, resolution_context)

    base_prompt =
      [language_ref, output_fmt]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    # Apply customization (prefix/suffix) but not string/function overrides
    # since those replace the entire prompt
    customized_prompt = apply_customization(base_prompt, agent.system_prompt)

    # Apply truncation if prompt_limit is set
    truncate_if_needed(customized_prompt, agent.prompt_limit)
  end

  @doc """
  Alias for `generate_system/2` for semantic clarity.

  See `generate_system/2` for documentation.
  """
  @spec generate_static(SubAgent.t(), keyword()) :: String.t()
  def generate_static(agent, opts \\ []), do: generate_system(agent, opts)

  @doc """
  Generate dynamic context sections (prepended to user message).

  Returns data inventory, tool schemas, and expected output - these sections vary
  per agent configuration but not per individual question.

  Note: The mission is NOT included here - it's already in the user message.

  ## Options

  - `:context` - Map of context variables for the data inventory
  - `:received_field_descriptions` - Field descriptions from upstream agent

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "Test", tools: %{"search" => fn _ -> [] end})
      iex> context_prompt = PtcRunner.SubAgent.SystemPrompt.generate_context(agent, context: %{x: 1})
      iex> context_prompt =~ ";; === data/ ===" and context_prompt =~ ";; === tools ==="
      true
      iex> context_prompt =~ "# Mission"
      false

  """
  @spec generate_context(SubAgent.t(), keyword()) :: String.t()
  def generate_context(%SubAgent{} = agent, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    received_field_descriptions = Keyword.get(opts, :received_field_descriptions)

    # Parse signature if present
    context_signature = parse_signature(agent.signature)

    # Merge agent context_descriptions into received_field_descriptions
    # Chained (received) descriptions take precedence (upstream agent knows better)
    all_field_descriptions =
      Map.merge(agent.context_descriptions || %{}, received_field_descriptions || %{})

    # Use compact Namespace format (same as Turn 2+)
    namespace_content =
      Namespace.render(%{
        tools: agent.tools,
        data: context,
        field_descriptions: all_field_descriptions,
        context_signature: context_signature,
        memory: %{},
        has_println: false
      })

    # Expected output stays as markdown (shared with Turn 2+)
    expected_output = Output.generate(context_signature, agent.field_descriptions)

    [namespace_content, expected_output]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Resolve a language_spec value to a string.

  ## Examples

      iex> PtcRunner.SubAgent.SystemPrompt.resolve_language_spec("custom prompt", %{})
      "custom prompt"

      iex> spec = PtcRunner.SubAgent.SystemPrompt.resolve_language_spec(:single_shot, %{})
      iex> is_binary(spec) and String.contains?(spec, "PTC-Lisp")
      true

      iex> callback = fn ctx -> if ctx.turn > 1, do: "multi", else: "single" end
      iex> PtcRunner.SubAgent.SystemPrompt.resolve_language_spec(callback, %{turn: 1})
      "single"

  """
  @spec resolve_language_spec(String.t() | atom() | (map() -> String.t()), map()) :: String.t()
  def resolve_language_spec(spec, context)

  def resolve_language_spec(spec, _context) when is_binary(spec), do: spec

  def resolve_language_spec(spec, _context) when is_atom(spec) do
    LanguageSpec.get!(spec)
  end

  def resolve_language_spec(spec, context) when is_function(spec, 1) do
    spec.(context)
  end

  @doc """
  Apply system prompt customization (string override, function, or map with prefix/suffix).

  ## Examples

      iex> PtcRunner.SubAgent.SystemPrompt.apply_customization("base", nil)
      "base"

      iex> PtcRunner.SubAgent.SystemPrompt.apply_customization("base", "override")
      "override"

      iex> PtcRunner.SubAgent.SystemPrompt.apply_customization("base", fn p -> "PREFIX\\n" <> p end)
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
      iex> PtcRunner.SubAgent.SystemPrompt.generate_error_recovery_prompt(error) =~ "Previous Turn Error"
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
    3. Calls tools with (tool/tool-name args)

    Please fix the issue and try again.
    """
  end

  @doc """
  Truncate prompt if it exceeds the configured character limit.

  ## Examples

      iex> PtcRunner.SubAgent.SystemPrompt.truncate_if_needed("short", nil)
      "short"

      iex> result = PtcRunner.SubAgent.SystemPrompt.truncate_if_needed(String.duplicate("x", 1000), %{max_chars: 100})
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
    context_signature = parse_signature(agent.signature)

    # Get static sections (language_ref, output_fmt)
    {language_ref, output_fmt} = resolve_static_sections(agent, resolution_context)

    # Merge agent context_descriptions into received_field_descriptions
    # Chained (received) descriptions take precedence (upstream agent knows better)
    all_field_descriptions =
      Map.merge(agent.context_descriptions || %{}, received_field_descriptions || %{})

    # Use compact Namespace format (same as Turn 2+)
    namespace_content =
      Namespace.render(%{
        tools: agent.tools,
        data: context,
        field_descriptions: all_field_descriptions,
        context_signature: context_signature,
        memory: %{},
        has_println: false
      })

    expected_output = Output.generate(context_signature, agent.field_descriptions)

    mission = expand_prompt(agent.prompt, context)

    # Combine all sections
    # language_ref contains role, rules, and language reference from priv/prompts/
    [
      language_ref,
      namespace_content,
      expected_output,
      output_fmt,
      "# Mission\n\n#{mission}"
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n")
  end

  defp expand_prompt(prompt, context) do
    case PromptExpander.expand(prompt, context) do
      {:ok, expanded} -> expanded
      {:error, {:missing_keys, _keys}} -> prompt
    end
  end

  # Resolve language_ref and output_fmt from agent config
  defp resolve_static_sections(%SubAgent{} = agent, resolution_context) do
    # Default language_spec: :multi_turn for loop mode, :single_shot for single-shot
    default_spec = if agent.max_turns > 1, do: :multi_turn, else: :single_shot

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
        {LanguageSpec.get(default_spec), @output_format}
    end
  end

  # Parse signature string to struct, returning nil on failure
  defp parse_signature(nil), do: nil

  defp parse_signature(sig_str) do
    case Signature.parse(sig_str) do
      {:ok, sig} -> sig
      {:error, _reason} -> nil
    end
  end
end
