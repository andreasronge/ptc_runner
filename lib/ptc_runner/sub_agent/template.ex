defmodule PtcRunner.SubAgent.Template do
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

      iex> PtcRunner.SubAgent.Template.expand("Hello {{name}}", %{name: "Alice"})
      {:ok, "Hello Alice"}

      iex> PtcRunner.SubAgent.Template.expand("User {{user.name}}", %{user: %{name: "Bob"}})
      {:ok, "User Bob"}

      iex> PtcRunner.SubAgent.Template.expand("Hello {{name}}", %{})
      {:error, {:missing_keys, ["name"]}}

      iex> PtcRunner.SubAgent.Template.extract_placeholders("Hello {{name}}, you have {{items.count}} items")
      [%{path: ["name"], type: :simple}, %{path: ["items", "count"], type: :simple}]

  """

  @placeholder_regex ~r/\{\{([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*)\}\}/

  @doc """
  Extract placeholders from a template string.

  Returns a list of unique placeholder structs, each containing:
  - `path`: List of strings representing the nested path (e.g., ["user", "name"])
  - `type`: Always `:simple` (iteration type is out of scope)

  ## Examples

      iex> PtcRunner.SubAgent.Template.extract_placeholders("Hello {{name}}")
      [%{path: ["name"], type: :simple}]

      iex> PtcRunner.SubAgent.Template.extract_placeholders("{{user.name}} has {{count}} items")
      [%{path: ["user", "name"], type: :simple}, %{path: ["count"], type: :simple}]

      iex> PtcRunner.SubAgent.Template.extract_placeholders("No placeholders here")
      []

      iex> PtcRunner.SubAgent.Template.extract_placeholders("{{name}} and {{name}}")
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
  Expand a template by replacing placeholders with values from the context.

  Returns `{:ok, expanded_string}` on success, or `{:error, {:missing_keys, keys}}`
  if any placeholders cannot be resolved.

  The context map can use either atom or string keys. Values are converted to
  strings using `to_string/1`.

  ## Examples

      iex> PtcRunner.SubAgent.Template.expand("Hello {{name}}", %{name: "Alice"})
      {:ok, "Hello Alice"}

      iex> PtcRunner.SubAgent.Template.expand("Count: {{count}}", %{count: 42})
      {:ok, "Count: 42"}

      iex> PtcRunner.SubAgent.Template.expand("{{a.b.c}}", %{a: %{b: %{c: "deep"}}})
      {:ok, "deep"}

      iex> PtcRunner.SubAgent.Template.expand("Hello", %{})
      {:ok, "Hello"}

      iex> PtcRunner.SubAgent.Template.expand("", %{})
      {:ok, ""}

      iex> PtcRunner.SubAgent.Template.expand("{{missing}}", %{})
      {:error, {:missing_keys, ["missing"]}}

      iex> PtcRunner.SubAgent.Template.expand("{{a}} and {{b}}", %{a: "1"})
      {:error, {:missing_keys, ["b"]}}

  """
  @spec expand(String.t(), map()) :: {:ok, String.t()} | {:error, {:missing_keys, [String.t()]}}
  def expand(template, context) when is_binary(template) and is_map(context) do
    placeholders = extract_placeholders(template)

    # Check all keys exist first
    missing = find_missing_keys(placeholders, context)

    if missing != [] do
      {:error, {:missing_keys, missing}}
    else
      result =
        Regex.replace(@placeholder_regex, template, fn _, path_str ->
          get_nested_value(context, String.split(path_str, "."))
          |> to_string()
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
