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

  @placeholder_regex ~r/\{\{([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*)\}\}/

  @doc """
  Extract placeholders from a template string.

  Returns a list of unique placeholder structs, each containing:
  - `path`: List of strings representing the nested path (e.g., ["user", "name"])
  - `type`: Always `:simple` (iteration type is out of scope)

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
    Regex.scan(@placeholder_regex, template)
    |> Enum.map(fn [_full, path_str] ->
      path = String.split(path_str, ".")
      %{path: path, type: :simple}
    end)
    |> Enum.uniq()
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
    placeholders = extract_placeholders(template)
    missing = find_missing_keys(placeholders, context)

    if missing != [] do
      {:error, {:missing_keys, missing}}
    else
      result =
        Regex.replace(@placeholder_regex, template, fn _full_match, path_str ->
          "~{data/#{path_str}}"
        end)

      {:ok, result}
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
    placeholders = extract_placeholders(template)

    # Check all keys exist first
    missing = find_missing_keys(placeholders, context)

    if missing != [] and on_missing == :error do
      {:error, {:missing_keys, missing}}
    else
      result =
        Regex.replace(@placeholder_regex, template, fn full_match, path_str ->
          path = String.split(path_str, ".")

          if has_nested_value?(context, path) do
            get_nested_value(context, path) |> to_string()
          else
            # When on_missing: :keep, return the original placeholder
            full_match
          end
        end)

      {:ok, result}
    end
  end

  # Find all missing keys in the context
  defp find_missing_keys(placeholders, context) do
    placeholders
    |> Enum.filter(fn %{path: path} ->
      not has_nested_value?(context, path)
    end)
    |> Enum.map(fn %{path: path} -> Enum.join(path, ".") end)
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

  # Get a nested value from the context
  defp get_nested_value(context, [key]) do
    get_from_map_with_key(context, key, :get)
  rescue
    ArgumentError -> Map.get(context, key)
  end

  defp get_nested_value(context, [key | rest]) do
    nested = get_from_map_with_key(context, key, :get)
    get_nested_value(nested, rest)
  rescue
    ArgumentError -> Map.get(context, key)
  end

  # Helper to get value from map, trying atom key first then string key
  defp get_from_map_with_key(map, key, :get) do
    Map.get(map, String.to_existing_atom(key)) || Map.get(map, key)
  end

  defp get_from_map_with_key(map, key, :has_key) do
    Map.has_key?(map, String.to_existing_atom(key)) || Map.has_key?(map, key)
  end
end
