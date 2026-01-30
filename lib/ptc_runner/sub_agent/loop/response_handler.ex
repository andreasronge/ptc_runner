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

  # Unicode characters that LLMs sometimes insert that break parsing:
  # - U+FEFF: BOM (Byte Order Mark)
  # - U+200B: Zero-width space
  # - U+200C: Zero-width non-joiner
  # - U+200D: Zero-width joiner
  # - U+00A0: Non-breaking space
  # - U+202F: Narrow no-break space
  # - U+2060: Word joiner
  # - U+FFFE: Invalid/reversed BOM
  # - U+00AD: Soft hyphen
  # - U+180E: Mongolian vowel separator
  # - U+2000-U+200A: Various width spaces
  @invisible_chars ~r/[\x{FEFF}\x{200B}\x{200C}\x{200D}\x{00A0}\x{202F}\x{2060}\x{FFFE}\x{00AD}\x{180E}\x{2000}-\x{200A}]/u

  # Smart/curly quotes that should be normalized to ASCII
  @smart_double_quotes ~r/[\x{201C}\x{201D}\x{201E}\x{201F}\x{2033}\x{2036}]/u
  @smart_single_quotes ~r/[\x{2018}\x{2019}\x{201A}\x{201B}\x{2032}\x{2035}]/u

  @doc """
  Parse PTC-Lisp from LLM response.

  Sanitizes LLM output by removing invisible Unicode characters (BOM, zero-width
  spaces) and normalizing smart quotes to ASCII equivalents.

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
    # Normalize line endings (CRLF -> LF, CR -> LF)
    response = String.replace(response, ~r/\r\n?/, "\n")

    # DEBUG: Show what we're parsing
    if System.get_env("DEBUG_PARSE") do
      IO.puts("\n=== DEBUG: Raw response (#{byte_size(response)} bytes) ===")
      IO.puts(response)
      IO.puts("=== END RAW RESPONSE ===\n")
    end

    # Try extracting from code blocks - prefer clojure/lisp tagged blocks
    # Allow optional whitespace/newline after language tag
    case Regex.scan(~r/```(?:clojure|lisp)[ \t]*\n?(.*?)```/s, response) do
      [] ->
        # Try any code blocks (skip optional language tag, then capture content)
        # Regex: ``` followed by optional non-newline chars (language tag), optional whitespace/newline, then content
        case Regex.scan(~r/```[^\n]*[ \t]*\n?(.*?)```/s, response) do
          [] ->
            try_raw_sexp(response)

          blocks ->
            # Filter blocks that look like Lisp code (start with parenthesis after trimming)
            lisp_blocks =
              blocks
              |> Enum.map(fn [_, code] -> String.trim(code) end)
              |> Enum.filter(&String.starts_with?(&1, "("))

            process_lisp_blocks(lisp_blocks, response)
        end

      [[_, code]] ->
        result = code |> String.trim() |> sanitize_code()

        if System.get_env("DEBUG_PARSE"),
          do:
            IO.puts(
              "=== DEBUG: Single clojure/lisp block extracted ===\n#{result}\n=== END EXTRACTED ===\n"
            )

        {:ok, result}

      blocks ->
        # Multiple blocks - use the last one (LLM self-corrected)
        code = blocks |> List.last() |> List.last() |> String.trim()
        result = sanitize_code(code)

        if System.get_env("DEBUG_PARSE"),
          do:
            IO.puts(
              "=== DEBUG: Using last of #{length(blocks)} clojure/lisp blocks ===\n#{result}\n=== END EXTRACTED ===\n"
            )

        {:ok, result}
    end
  end

  # Process filtered lisp blocks, falling back to raw s-expression if none found
  defp process_lisp_blocks([], response) do
    try_raw_sexp(response)
  end

  defp process_lisp_blocks([single], _response) do
    {:ok, sanitize_code(single)}
  end

  defp process_lisp_blocks(multiple, _response) do
    # Multiple blocks - use the last one (LLM self-corrected)
    {:ok, sanitize_code(List.last(multiple))}
  end

  # Try to extract raw s-expression from response
  defp try_raw_sexp(response) do
    sanitized = response |> String.trim() |> sanitize_code()

    if String.starts_with?(sanitized, "(") do
      {:ok, sanitized}
    else
      {:error, :no_code_in_response}
    end
  end

  # Remove invisible Unicode characters, normalize smart quotes to ASCII,
  # and strip unsupported reader macros. LLMs sometimes produce these which break the parser.
  # Always trims the result since #_ stripping can leave leading whitespace.
  defp sanitize_code(code) do
    code
    |> String.replace(@invisible_chars, "")
    |> String.replace(@smart_double_quotes, "\"")
    |> String.replace(@smart_single_quotes, "'")
    |> strip_discard_reader_macros()
    |> String.trim()
  end

  # Strip #_ reader macros (discard next form).
  # Handles: #_symbol, #_(expr), #_[expr], #_{expr}
  # Applied iteratively since #_ can be nested: #_#_foo discards two forms
  defp strip_discard_reader_macros(code) do
    # Pattern: #_ followed by either:
    # - a balanced delimited form (parens, brackets, braces)
    # - or a symbol/number (sequence of non-whitespace, non-delimiter chars)
    result = do_strip_discard(code)

    if result == code do
      code
    else
      # Keep stripping in case of nested #_
      strip_discard_reader_macros(result)
    end
  end

  defp do_strip_discard(code) do
    case Regex.run(~r/#_\s*/, code, return: :index) do
      [{start, len}] ->
        prefix = String.slice(code, 0, start)
        rest = String.slice(code, start + len, String.length(code))

        case skip_next_form(rest) do
          {:ok, remaining} ->
            prefix <> remaining

          :error ->
            # Can't parse the form, leave #_ in place (will cause parse error)
            code
        end

      _ ->
        code
    end
  end

  # Skip the next Lisp form and return the remaining string
  defp skip_next_form(str) do
    str = String.trim_leading(str)

    cond do
      String.starts_with?(str, "(") -> skip_balanced(str, "(", ")")
      String.starts_with?(str, "[") -> skip_balanced(str, "[", "]")
      String.starts_with?(str, "{") -> skip_balanced(str, "{", "}")
      String.starts_with?(str, "\"") -> skip_string(str)
      # Handle nested #_ - skip #_ and then the form it's discarding
      String.starts_with?(str, "#_") -> skip_discard_form(str)
      true -> skip_symbol(str)
    end
  end

  # Skip a #_ reader macro and the form it discards
  defp skip_discard_form(str) do
    # Skip the #_ prefix
    rest = String.slice(str, 2, String.length(str))
    # Then skip the form being discarded
    skip_next_form(rest)
  end

  defp skip_balanced(str, open, close) do
    # Find matching close delimiter, respecting nesting
    do_skip_balanced(String.graphemes(str), 0, open, close, [])
  end

  defp do_skip_balanced([], _depth, _open, _close, _acc), do: :error

  defp do_skip_balanced([char | rest], depth, open, close, acc) do
    new_depth =
      cond do
        char == open -> depth + 1
        char == close -> depth - 1
        true -> depth
      end

    if new_depth == 0 do
      {:ok, Enum.join(rest)}
    else
      do_skip_balanced(rest, new_depth, open, close, [char | acc])
    end
  end

  defp skip_string(str) do
    # Skip opening quote, then find unescaped closing quote
    case Regex.run(~r/^"(?:[^"\\]|\\.)*"(.*)$/s, str) do
      [_, rest] -> {:ok, rest}
      _ -> :error
    end
  end

  defp skip_symbol(str) do
    # Symbol is sequence of non-whitespace, non-delimiter chars
    case Regex.run(~r/^[^\s\(\)\[\]\{\}"]+(.*)$/s, str) do
      [_, rest] -> {:ok, rest}
      _ -> :error
    end
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

  REPL-style output: just the expression result, no prefix.
  Use `def` to explicitly store values that persist across turns.

  Returns `{formatted_string, truncated?}` tuple.

  ## Options

  Uses `format_options` from SubAgent:
  - `:feedback_limit` - Max collection items (default: 10)
  - `:feedback_max_chars` - Max chars in feedback (default: 512)

  ## Examples

      iex> PtcRunner.SubAgent.Loop.ResponseHandler.format_execution_result(42)
      {"42", false}

      iex> PtcRunner.SubAgent.Loop.ResponseHandler.format_execution_result(%{count: 5})
      {"{:count 5}", false}

  """
  @spec format_execution_result(term(), keyword()) :: {String.t(), boolean()}
  def format_execution_result(result, format_options \\ []) do
    limit = Keyword.get(format_options, :feedback_limit, 10)
    max_chars = Keyword.get(format_options, :feedback_max_chars, 512)

    {formatted, format_truncated} =
      Format.to_clojure(result, limit: limit, printable_limit: max_chars)

    {final_str, char_truncated} = truncate_feedback(formatted, max_chars)
    {final_str, format_truncated or char_truncated}
  end

  defp truncate_feedback(str, max_chars) when byte_size(str) > max_chars do
    {String.slice(str, 0, max_chars) <> "... (truncated)", true}
  end

  defp truncate_feedback(str, _max_chars), do: {str, false}

  @doc """
  Format final result for caller.

  Uses `format_options` from SubAgent:
  - `:result_limit` - Inspect limit for collections (default: 50)
  - `:result_max_chars` - Max chars in result (default: 500)

  ## Examples

      iex> PtcRunner.SubAgent.Loop.ResponseHandler.format_result(42)
      "42"

      iex> PtcRunner.SubAgent.Loop.ResponseHandler.format_result(3.14159)
      "3.14"

      iex> PtcRunner.SubAgent.Loop.ResponseHandler.format_result([1, 2, 3])
      "[1, 2, 3]"

  """
  @spec format_result(term(), keyword()) :: String.t()
  def format_result(result, format_options \\ [])

  def format_result(result, _opts) when is_float(result) do
    :erlang.float_to_binary(result, decimals: 2)
  end

  def format_result(result, _opts) when is_integer(result) do
    Integer.to_string(result)
  end

  def format_result(result, format_options) do
    limit = Keyword.get(format_options, :result_limit, 50)
    max_chars = Keyword.get(format_options, :result_max_chars, 500)

    result
    |> inspect(limit: limit, pretty: false)
    |> truncate_result(max_chars)
  end

  defp truncate_result(str, max_chars) when byte_size(str) > max_chars do
    String.slice(str, 0, max_chars) <> "..."
  end

  defp truncate_result(str, _max_chars), do: str

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
