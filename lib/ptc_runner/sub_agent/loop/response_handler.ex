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

  For map results in multi-turn mode, includes guidance about memory storage
  so the LLM knows to access values via `memory/key` in subsequent turns.

  ## Parameters

  - `result` - The execution result
  - `opts` - Options:
    - `:show_memory_hints` - Whether to show memory access hints (default: true)

  ## Examples

      iex> PtcRunner.SubAgent.Loop.ResponseHandler.format_execution_result(42)
      "Result: 42"

      iex> result = PtcRunner.SubAgent.Loop.ResponseHandler.format_execution_result(%{count: 5, items: []})
      iex> result =~ "memory/count"
      true

      iex> result = PtcRunner.SubAgent.Loop.ResponseHandler.format_execution_result(%{count: 5}, show_memory_hints: false)
      iex> result =~ "memory/"
      false

  """
  @spec format_execution_result(term(), keyword()) :: String.t()
  def format_execution_result(result, opts \\ [])

  def format_execution_result(result, opts) when is_map(result) and map_size(result) > 0 do
    result_str = inspect(result, limit: :infinity, printable_limit: :infinity)
    show_hints = Keyword.get(opts, :show_memory_hints, true)

    if show_hints do
      memory_keys =
        result
        |> Map.keys()
        |> Enum.map(fn
          k when is_atom(k) -> "memory/#{k}"
          k when is_binary(k) -> "memory/#{k}"
          k -> "memory/#{inspect(k)}"
        end)
        |> Enum.join(", ")

      """
      Result: #{result_str}

      Stored in memory. Access via: #{memory_keys}
      """
      |> String.trim()
    else
      "Result: #{result_str}"
    end
  end

  def format_execution_result(result, _opts) do
    "Result: #{inspect(result, limit: :infinity, printable_limit: :infinity)}"
  end
end
