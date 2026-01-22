defmodule PtcRunner.SubAgent.PromptExpander do
  @moduledoc """
  Template string expansion with placeholder validation.

  Provides functions to:
  - Extract placeholders from template strings
  - Expand templates by replacing placeholders with values from a context map

  ## Placeholder Syntax

  Placeholders use `{{variable}}` syntax and support nested access with dot notation:

  - Simple: `{{name}}`
  - Nested: `{{user.name}}` or `{{items.count}}`

  ## Mustache Sections (JSON Mode Only)

  The `expand/3` function supports Mustache sections for iterating over lists:

  - List iteration: `{{#items}}{{name}} {{/items}}`
  - Scalar lists with dot: `{{#tags}}{{.}} {{/tags}}`
  - Inverted sections: `{{^items}}No items{{/items}}`

  **Note:** Sections are intended for JSON mode agents where data is embedded directly
  in the prompt. For PTC-Lisp mode, use `expand_annotated/2` which returns annotations
  like `~{data/var}` and does not support sections (the Data Inventory is flat).

  ## Examples

      iex> PtcRunner.SubAgent.PromptExpander.expand("Hello {{name}}", %{name: "Alice"})
      {:ok, "Hello Alice"}

      iex> PtcRunner.SubAgent.PromptExpander.expand("User {{user.name}}", %{user: %{name: "Bob"}})
      {:ok, "User Bob"}

      iex> PtcRunner.SubAgent.PromptExpander.expand("Hello {{name}}", %{})
      {:error, {:missing_keys, ["name"]}}

      iex> PtcRunner.SubAgent.PromptExpander.extract_placeholders("Hello {{name}}, you have {{items.count}} items")
      [%{path: ["name"], type: :simple}, %{path: ["items", "count"], type: :simple}]

  """

  alias PtcRunner.Mustache

  @doc """
  Extract placeholders from a template string.

  Returns a list of unique placeholder structs, each containing:
  - `path`: List of strings representing the nested path (e.g., ["user", "name"])
  - `type`: Always `:simple` (for backward compatibility, section names are flattened)

  ## Examples

      iex> PtcRunner.SubAgent.PromptExpander.extract_placeholders("Hello {{name}}")
      [%{path: ["name"], type: :simple}]

      iex> PtcRunner.SubAgent.PromptExpander.extract_placeholders("{{user.name}} has {{count}} items")
      [%{path: ["user", "name"], type: :simple}, %{path: ["count"], type: :simple}]

      iex> PtcRunner.SubAgent.PromptExpander.extract_placeholders("No placeholders here")
      []

      iex> PtcRunner.SubAgent.PromptExpander.extract_placeholders("{{name}} and {{name}}")
      [%{path: ["name"], type: :simple}]

  """
  @spec extract_placeholders(String.t()) :: [%{path: [String.t()], type: :simple}]
  def extract_placeholders(template) when is_binary(template) do
    case Mustache.parse(template) do
      {:ok, ast} ->
        ast
        |> Mustache.extract_variables()
        |> flatten_to_simple_variables()
        |> Enum.uniq_by(& &1.path)

      {:error, _} ->
        # On parse error, return empty list (matches old regex behavior for invalid syntax)
        []
    end
  end

  # Flatten sections to their name only, return all as :simple type for backward compatibility
  defp flatten_to_simple_variables(vars) do
    Enum.flat_map(vars, fn
      %{type: :simple, path: path} ->
        # Skip the special "." placeholder (current element in sections)
        if path == ["."], do: [], else: [%{path: path, type: :simple}]

      %{type: type, path: path} when type in [:section, :inverted_section] ->
        # Include section name as simple variable for backward compatibility
        [%{path: path, type: :simple}]
    end)
  end

  @doc """
  Extract all placeholders with full section information.

  Unlike `extract_placeholders/1`, this returns the complete variable structure
  including section types and nested fields. Used for signature validation in Phase 3.

  ## Examples

      iex> PtcRunner.SubAgent.PromptExpander.extract_placeholders_with_sections("{{name}}")
      [%{type: :simple, path: ["name"], fields: nil, loc: %{line: 1, col: 1}}]

      iex> {:ok, [section]} = {:ok, PtcRunner.SubAgent.PromptExpander.extract_placeholders_with_sections("{{#items}}{{name}}{{/items}}")}
      iex> section.type
      :section
      iex> section.path
      ["items"]
      iex> [field] = section.fields
      iex> field.path
      ["name"]

  """
  @spec extract_placeholders_with_sections(String.t()) :: [Mustache.variable_info()]
  def extract_placeholders_with_sections(template) when is_binary(template) do
    case Mustache.parse(template) do
      {:ok, ast} -> Mustache.extract_variables(ast)
      {:error, _} -> []
    end
  end

  @doc """
  Extract placeholder names from a template string as a flat list.

  This is a convenience wrapper around `extract_placeholders/1` that returns
  only the placeholder names as flat strings (e.g., "name", "user.name").

  ## Examples

      iex> PtcRunner.SubAgent.PromptExpander.extract_placeholder_names("Hello {{name}}")
      ["name"]

      iex> PtcRunner.SubAgent.PromptExpander.extract_placeholder_names("{{user.name}} has {{count}} items")
      ["user.name", "count"]

      iex> PtcRunner.SubAgent.PromptExpander.extract_placeholder_names("No placeholders here")
      []

      iex> PtcRunner.SubAgent.PromptExpander.extract_placeholder_names("{{name}} and {{name}}")
      ["name"]

  """
  @spec extract_placeholder_names(String.t()) :: [String.t()]
  def extract_placeholder_names(template) when is_binary(template) do
    template
    |> extract_placeholders()
    |> Enum.map(fn %{path: path} -> Enum.join(path, ".") end)
  end

  @doc """
  Extract parameter names from a SubAgent signature string.

  Parses the signature and returns a list of parameter names.
  Returns an empty list if the signature cannot be parsed.

  ## Examples

      iex> PtcRunner.SubAgent.PromptExpander.extract_signature_params("(user :string) -> :string")
      ["user"]

      iex> PtcRunner.SubAgent.PromptExpander.extract_signature_params("(name :string, age :int) -> :string")
      ["name", "age"]

      iex> PtcRunner.SubAgent.PromptExpander.extract_signature_params("invalid signature")
      []

  """
  @spec extract_signature_params(String.t()) :: [String.t()]
  def extract_signature_params(signature) when is_binary(signature) do
    alias PtcRunner.SubAgent.Signature.Parser

    case Parser.parse(signature) do
      {:ok, {:signature, params, _output}} ->
        Enum.map(params, fn {name, _type} -> name end)

      {:error, _reason} ->
        # If signature parsing fails, we can't extract params
        # Let the signature validation fail elsewhere
        []
    end
  end

  @doc """
  Expand a template with annotations showing where substitutions occurred.

  Returns an annotated string where substituted values are wrapped with `~{data/...}`
  syntax to make it clear which parts came from template variables. This is useful
  for debugging to distinguish dynamic values from hardcoded text.

  ## Examples

      iex> PtcRunner.SubAgent.PromptExpander.expand_annotated("Hello {{name}}", %{name: "Alice"})
      {:ok, "Hello ~{data/name}"}

      iex> PtcRunner.SubAgent.PromptExpander.expand_annotated("Count: {{count}}", %{count: 42})
      {:ok, "Count: ~{data/count}"}

      iex> PtcRunner.SubAgent.PromptExpander.expand_annotated("{{a.b}}", %{a: %{b: "deep"}})
      {:ok, "~{data/a.b}"}

      iex> PtcRunner.SubAgent.PromptExpander.expand_annotated("Hello", %{})
      {:ok, "Hello"}

      iex> PtcRunner.SubAgent.PromptExpander.expand_annotated("{{missing}}", %{})
      {:error, {:missing_keys, ["missing"]}}

  """
  @spec expand_annotated(String.t(), map()) ::
          {:ok, String.t()} | {:error, {:missing_keys, [String.t()]}}
  def expand_annotated(template, context) when is_binary(template) and is_map(context) do
    case Mustache.parse(template) do
      {:ok, ast} ->
        # Check for sections - annotated mode only supports simple variables
        # (Sections are for JSON mode only where data is embedded directly)
        if has_sections?(ast) do
          {:error, {:sections_not_supported, "expand_annotated does not support sections"}}
        else
          # Validate all keys present
          missing = find_missing_simple_keys(ast, context)

          if missing != [] do
            {:error, {:missing_keys, missing}}
          else
            # Replace variables with annotations
            result = annotate_ast(ast)
            {:ok, result}
          end
        end

      {:error, _} ->
        # On parse error, fall back to returning template unchanged
        {:ok, template}
    end
  end

  @doc """
  Expand a template by replacing placeholders with values from the context.

  Returns `{:ok, expanded_string}` on success, or `{:error, {:missing_keys, keys}}`
  if any placeholders cannot be resolved (when `on_missing: :error`).

  The context map can use either atom or string keys. Values are converted to
  strings using `to_string/1`.

  ## Options

  - `on_missing`: Controls behavior when a placeholder key is missing from the context.
    - `:error` (default) - Returns `{:error, {:missing_keys, [...]}}` if any keys are missing
    - `:keep` - Leaves missing placeholders unchanged in the output (e.g., `"{{name}}"`)

  ## Examples

      iex> PtcRunner.SubAgent.PromptExpander.expand("Hello {{name}}", %{name: "Alice"})
      {:ok, "Hello Alice"}

      iex> PtcRunner.SubAgent.PromptExpander.expand("Count: {{count}}", %{count: 42})
      {:ok, "Count: 42"}

      iex> PtcRunner.SubAgent.PromptExpander.expand("{{a.b.c}}", %{a: %{b: %{c: "deep"}}})
      {:ok, "deep"}

      iex> PtcRunner.SubAgent.PromptExpander.expand("Hello", %{})
      {:ok, "Hello"}

      iex> PtcRunner.SubAgent.PromptExpander.expand("", %{})
      {:ok, ""}

      iex> PtcRunner.SubAgent.PromptExpander.expand("{{missing}}", %{})
      {:error, {:missing_keys, ["missing"]}}

      iex> PtcRunner.SubAgent.PromptExpander.expand("{{a}} and {{b}}", %{a: "1"})
      {:error, {:missing_keys, ["b"]}}

      iex> PtcRunner.SubAgent.PromptExpander.expand("{{missing}}", %{}, on_missing: :keep)
      {:ok, "{{missing}}"}

      iex> PtcRunner.SubAgent.PromptExpander.expand("{{a}} and {{b}}", %{a: "1"}, on_missing: :keep)
      {:ok, "1 and {{b}}"}

  """
  @spec expand(String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, {:missing_keys, [String.t()]}}
  def expand(template, context, opts \\ [])
      when is_binary(template) and is_map(context) and is_list(opts) do
    on_missing = Keyword.get(opts, :on_missing, :error)

    case Mustache.parse(template) do
      {:ok, ast} ->
        # Check if template uses sections - affects context preprocessing
        uses_sections = has_sections?(ast)
        expand_with_mustache(ast, context, on_missing, template, uses_sections)

      {:error, _} ->
        # On parse error, return template unchanged
        {:ok, template}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Check if AST contains any sections
  defp has_sections?(ast) do
    Enum.any?(ast, fn
      {:section, _, _, _} -> true
      {:inverted_section, _, _, _} -> true
      _ -> false
    end)
  end

  # Find missing simple variable keys (not section names)
  # Section names that are missing will just not render, which is standard Mustache behavior
  defp find_missing_simple_keys(ast, context) do
    ast
    |> Enum.flat_map(fn
      {:variable, path, _loc} ->
        if has_nested_value?(context, path), do: [], else: [Enum.join(path, ".")]

      {:section, _name, inner, _loc} ->
        # Recursively check inner content for missing simple variables
        find_missing_simple_keys(inner, context)

      {:inverted_section, _name, inner, _loc} ->
        # Recursively check inner content for missing simple variables
        find_missing_simple_keys(inner, context)

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  # Expand using Mustache, handling on_missing: :keep
  # When uses_sections is true, keep lists/maps as-is for Mustache iteration
  # When uses_sections is false, stringify lists for backward compatibility
  defp expand_with_mustache(ast, context, on_missing, original_template, uses_sections) do
    # Find missing simple variable keys (not section names)
    missing = find_missing_simple_keys(ast, context)

    if missing != [] and on_missing == :error do
      {:error, {:missing_keys, missing}}
    else
      # Prepare context based on whether sections are used
      prepared_context =
        if uses_sections do
          # Keep lists as-is for Mustache section iteration
          stringify_keys(context)
        else
          # Backward compat: stringify lists for simple variable expansion
          stringify_values_for_expansion(context)
        end

      if missing != [] and on_missing == :keep do
        # Build fallback context with missing keys mapped to their original placeholder strings
        # Only for simple variables, not section names (missing sections just don't render)
        fallback_context =
          Enum.reduce(missing, %{}, fn key, acc ->
            Map.put(acc, key, "{{#{key}}}")
          end)

        # Merge fallback with prepared context (actual values take precedence)
        merged_context = Map.merge(fallback_context, prepared_context)

        case Mustache.expand(ast, merged_context) do
          {:ok, result} -> {:ok, result}
          {:error, _} -> {:ok, original_template}
        end
      else
        case Mustache.expand(ast, prepared_context) do
          {:ok, result} -> {:ok, result}
          {:error, _} -> {:ok, original_template}
        end
      end
    end
  end

  # Convert nested map keys to strings for Mustache compatibility
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_map(v) -> {to_string(k), stringify_keys(v)}
      {k, v} when is_list(v) -> {to_string(k), Enum.map(v, &maybe_stringify_keys/1)}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp maybe_stringify_keys(v) when is_map(v), do: stringify_keys(v)
  defp maybe_stringify_keys(v), do: v

  # Convert non-scalar values to strings for simple variable expansion
  # This matches old regex-based behavior which called to_string/1 on any value
  defp stringify_values_for_expansion(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_map(v) ->
        # Nested maps: recurse to handle nested access like {{user.name}}
        {to_string(k), stringify_values_for_expansion(v)}

      {k, v} when is_list(v) ->
        # Lists at top level: convert to string representation
        {to_string(k), to_string(inspect(v))}

      {k, v} ->
        # Scalars: keep as-is (Mustache will convert via to_string)
        {to_string(k), v}
    end)
  end

  # Replace variables with annotations by walking AST
  defp annotate_ast(ast) do
    ast
    |> Enum.map(fn
      {:text, text} ->
        text

      {:variable, path, _loc} ->
        path_str = Enum.join(path, ".")
        "~{data/#{path_str}}"

      {:comment, _, _} ->
        ""

      {:current, _loc} ->
        "~{data/.}"

      other ->
        # Shouldn't happen if has_sections? returned false
        inspect(other)
    end)
    |> IO.iodata_to_binary()
  end

  # Check if a nested value exists in the context
  defp has_nested_value?(context, [key]) do
    get_from_map_with_key(context, key, :has_key)
  rescue
    ArgumentError -> Map.has_key?(context, key)
  end

  defp has_nested_value?(context, [key | rest]) do
    nested = get_from_map_with_key(context, key, :get)

    if is_map(nested) do
      has_nested_value?(nested, rest)
    else
      false
    end
  rescue
    ArgumentError -> false
  end

  # Helper to get value from map, trying atom key first then string key
  defp get_from_map_with_key(map, key, :get) do
    Map.get(map, String.to_existing_atom(key)) || Map.get(map, key)
  end

  defp get_from_map_with_key(map, key, :has_key) do
    Map.has_key?(map, String.to_existing_atom(key)) || Map.has_key?(map, key)
  end
end
