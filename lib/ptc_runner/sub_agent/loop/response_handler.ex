defmodule PtcRunner.SubAgent.Loop.ResponseHandler do
  @moduledoc """
  Response parsing and validation for LLM responses.

  This module handles extracting PTC-Lisp code from LLM responses and
  formatting execution results for LLM feedback.

  ## Parsing Strategy

  1. Try extracting from ```clojure or ```lisp code blocks
  2. Fall back to raw s-expression starting with '('
  3. Multiple code blocks are wrapped in a (do ...) form
  """

  alias PtcRunner.Lisp.Format

  @doc """
  Parse PTC-Lisp from LLM response.

  ## Examples

      iex> PtcRunner.SubAgent.Loop.ResponseHandler.parse("```clojure\\n(+ 1 2)\\n```")
      {:ok, "(+ 1 2)"}

      iex> PtcRunner.SubAgent.Loop.ResponseHandler.parse("(return {:result 42})")
      {:ok, "(return {:result 42})"}

      iex> PtcRunner.SubAgent.Loop.ResponseHandler.parse("I'm thinking about this...")
      {:error, :no_code_in_response}

  ## Returns

  - `{:ok, code}` - Successfully extracted code string
  - `{:error, :no_code_in_response}` - No valid PTC-Lisp found
  """
  @spec parse(String.t()) :: {:ok, String.t()} | {:error, :no_code_in_response}
  def parse(response) do
    # Try extracting from code blocks (clojure or lisp)
    case Regex.scan(~r/```(?:clojure|lisp)\n(.*?)```/s, response) do
      [] ->
        # Try raw s-expression
        trimmed = String.trim(response)

        if String.starts_with?(trimmed, "(") do
          {:ok, trimmed}
        else
          {:error, :no_code_in_response}
        end

      [[_, code]] ->
        {:ok, String.trim(code)}

      blocks ->
        # Multiple blocks - wrap in do
        code = Enum.map_join(blocks, "\n", &List.last/1)
        {:ok, "(do #{code})"}
    end
  end

  @doc """
  Check if code calls a catalog-only tool (not in executable tools).

  ## Parameters

  - `code` - The PTC-Lisp code to check
  - `executable_tools` - Map of tools that can be executed
  - `tool_catalog` - Map of planning-only tools

  ## Returns

  - `:ok` - No catalog-only tool calls found
  - `{:error, tool_name}` - Found call to catalog-only tool
  """
  @spec find_catalog_tool_call(String.t(), map(), map() | nil) :: :ok | {:error, String.t()}
  def find_catalog_tool_call(code, executable_tools, tool_catalog) do
    # Only check if tool_catalog exists and is not empty
    if tool_catalog && map_size(tool_catalog) > 0 do
      # Find catalog-only tools (in catalog but not in executable tools)
      catalog_only = Map.keys(tool_catalog) -- Map.keys(executable_tools)

      # Check if code contains a call to any catalog-only tool
      Enum.find_value(catalog_only, :ok, fn tool_name ->
        if contains_call?(code, tool_name) do
          {:error, tool_name}
        else
          nil
        end
      end)
    else
      :ok
    end
  end

  @doc """
  Check if code contains a call to a specific tool.

  Recognizes both standard call syntax `(call "tool_name" ...)` and
  shorthand syntax for return/fail `(return ...)` / `(fail ...)`.
  """
  @spec contains_call?(String.t(), String.t()) :: boolean()
  def contains_call?(code, tool_name) do
    # Standard call pattern for all tools
    call_match = Regex.match?(~r/\(call\s+"#{tool_name}"/, code)

    # Shorthand only for return and fail
    shorthand_match =
      tool_name in ["return", "fail"] and
        Regex.match?(~r/\(#{tool_name}[\s\{]/, code)

    call_match or shorthand_match
  end

  @doc """
  Format error for LLM feedback.
  """
  @spec format_error_for_llm(map()) :: String.t()
  def format_error_for_llm(fail) do
    "Error: #{fail.message}"
  end

  @doc """
  Format execution result for LLM feedback.

  V2 simplified model: result is just displayed as-is. No implicit memory storage.
  Use `def` to explicitly store values that persist across turns.

  ## Examples

      iex> PtcRunner.SubAgent.Loop.ResponseHandler.format_execution_result(42)
      "Result: 42"

      iex> PtcRunner.SubAgent.Loop.ResponseHandler.format_execution_result(%{count: 5})
      "Result: {:count 5}"

  """
  @spec format_execution_result(term()) :: String.t()
  def format_execution_result(result) do
    "Result: #{Format.to_clojure(result, limit: :infinity, printable_limit: :infinity)}"
  end

  # Default maximum size for turn history entries (1KB)
  @default_max_history_bytes 1024

  @doc """
  Truncate a result value for storage in turn history.

  Large results are truncated to prevent memory bloat. The default limit is 1KB.
  Truncation preserves structure where possible:
  - Lists: keeps first N elements that fit
  - Maps: keeps first N key-value pairs that fit
  - Strings: truncates with "..." suffix
  - Other values: converted to truncated string representation

  ## Options

  - `:max_bytes` - Maximum size in bytes (default: 1024)

  ## Examples

      iex> PtcRunner.SubAgent.Loop.ResponseHandler.truncate_for_history([1, 2, 3])
      [1, 2, 3]

      iex> result = PtcRunner.SubAgent.Loop.ResponseHandler.truncate_for_history(String.duplicate("x", 2000))
      iex> byte_size(result) <= 1024
      true

  """
  @spec truncate_for_history(term(), keyword()) :: term()
  def truncate_for_history(value, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_history_bytes)
    do_truncate(value, max_bytes)
  end

  defp do_truncate(value, max_bytes) do
    current_size = :erlang.external_size(value)

    if current_size <= max_bytes do
      value
    else
      truncate_value(value, max_bytes)
    end
  end

  # Truncate strings with "..." suffix
  defp truncate_value(value, max_bytes) when is_binary(value) do
    # Reserve space for "..." suffix
    target_size = max_bytes - 3

    if target_size > 0 do
      String.slice(value, 0, target_size) <> "..."
    else
      "..."
    end
  end

  # Truncate lists by keeping first elements that fit
  defp truncate_value(value, max_bytes) when is_list(value) do
    truncate_list(value, [], 0, max_bytes)
  end

  # Truncate maps by keeping first entries that fit
  defp truncate_value(value, max_bytes) when is_map(value) do
    truncate_map(Map.to_list(value), %{}, 0, max_bytes)
  end

  # For other types, convert to string representation and truncate
  defp truncate_value(value, max_bytes) do
    inspected = Format.to_string(value, limit: 50, printable_limit: max_bytes)
    truncate_value(inspected, max_bytes)
  end

  defp truncate_list([], acc, _size, _max), do: Enum.reverse(acc)

  defp truncate_list([head | tail], acc, current_size, max_bytes) do
    head_size = :erlang.external_size(head)
    new_size = current_size + head_size

    if new_size <= max_bytes do
      truncate_list(tail, [head | acc], new_size, max_bytes)
    else
      # Try to truncate the head if it's large
      truncated_head = do_truncate(head, max_bytes - current_size)
      Enum.reverse([truncated_head | acc])
    end
  end

  defp truncate_map([], acc, _size, _max), do: acc

  defp truncate_map([{k, v} | tail], acc, current_size, max_bytes) do
    entry_size = :erlang.external_size({k, v})
    new_size = current_size + entry_size

    if new_size <= max_bytes do
      truncate_map(tail, Map.put(acc, k, v), new_size, max_bytes)
    else
      # Try to truncate the value if it's large
      truncated_v = do_truncate(v, max_bytes - current_size - :erlang.external_size(k))
      Map.put(acc, k, truncated_v)
    end
  end
end
