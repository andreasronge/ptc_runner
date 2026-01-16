defmodule PtcRunner.SubAgent.JsonParser do
  @moduledoc """
  Extracts JSON from LLM responses, handling common formatting quirks.

  LLMs often wrap JSON in markdown code blocks, add explanatory text,
  or include trailing commentary. This module extracts the JSON content
  following a priority order:

  1. JSON in ```json code block
  2. JSON in ``` code block (no language)
  3. Raw JSON object (starts with `{`)
  4. Raw JSON array (starts with `[`)

  ## Examples

      iex> PtcRunner.SubAgent.JsonParser.parse(~s|{"name": "Alice"}|)
      {:ok, %{"name" => "Alice"}}

      iex> PtcRunner.SubAgent.JsonParser.parse("```json\\n{\\"a\\": 1}\\n```")
      {:ok, %{"a" => 1}}

      iex> PtcRunner.SubAgent.JsonParser.parse("Here's the result: {\\"x\\": 5}")
      {:ok, %{"x" => 5}}

      iex> PtcRunner.SubAgent.JsonParser.parse("No JSON here")
      {:error, :no_json_found}

  """

  @doc """
  Parse JSON from an LLM response string.

  Extracts JSON from code blocks or raw content, handling common LLM
  formatting quirks like trailing text or explanation prefixes.

  Returns `{:ok, term()}` with the parsed JSON data, or an error tuple.

  ## Error Types

  - `{:error, :no_json_found}` - No JSON structure detected in the response
  - `{:error, :invalid_json}` - JSON was found but failed to parse

  ## Examples

      iex> PtcRunner.SubAgent.JsonParser.parse(~s|{"count": 42}|)
      {:ok, %{"count" => 42}}

      iex> PtcRunner.SubAgent.JsonParser.parse("[1, 2, 3]")
      {:ok, [1, 2, 3]}

      iex> PtcRunner.SubAgent.JsonParser.parse("```json\\n{\\"valid\\": true}\\n```")
      {:ok, %{"valid" => true}}

      iex> PtcRunner.SubAgent.JsonParser.parse("plain text")
      {:error, :no_json_found}

      iex> PtcRunner.SubAgent.JsonParser.parse("```json\\n{invalid}\\n```")
      {:error, :invalid_json}

  """
  @spec parse(String.t()) :: {:ok, term()} | {:error, :no_json_found | :invalid_json}
  def parse(response) when is_binary(response) do
    case extract_json_code_block(response) do
      {:ok, data} ->
        {:ok, data}

      {:error, :invalid_json} ->
        # Code block found but JSON was malformed - don't fall through
        {:error, :invalid_json}

      {:error, _} ->
        # No code block or empty - try raw JSON extraction
        case extract_raw_json(response) do
          {:ok, data} -> {:ok, data}
          {:error, :invalid_json} -> {:error, :invalid_json}
          {:error, _} -> {:error, :no_json_found}
        end
    end
  end

  # Extract JSON from ```json ... ``` or ``` ... ``` code blocks
  defp extract_json_code_block(response) do
    # Match ```json ... ``` or ``` ... ``` (no language tag)
    regex = ~r/```(?:json)?\s*\n?([\s\S]*?)\n?```/

    case Regex.run(regex, response) do
      [_, json] ->
        trimmed = String.trim(json)

        if trimmed == "" do
          {:error, :empty_code_block}
        else
          decode_json(trimmed)
        end

      nil ->
        {:error, :no_code_block}
    end
  end

  # Extract raw JSON object or array from the response
  defp extract_raw_json(response) do
    trimmed = String.trim(response)

    cond do
      String.starts_with?(trimmed, "{") -> extract_json_object(trimmed)
      String.starts_with?(trimmed, "[") -> extract_json_array(trimmed)
      # Try to find JSON embedded in the text (e.g., "Here's the result: {...}")
      true -> find_embedded_json(response)
    end
  end

  # Extract a JSON object by finding the matching closing brace
  defp extract_json_object(text) do
    case find_matching_bracket(text, ?{, ?}) do
      {:ok, json_str} -> decode_json(json_str)
      :error -> {:error, :no_json_found}
    end
  end

  # Extract a JSON array by finding the matching closing bracket
  defp extract_json_array(text) do
    case find_matching_bracket(text, ?[, ?]) do
      {:ok, json_str} -> decode_json(json_str)
      :error -> {:error, :no_json_found}
    end
  end

  # Find JSON embedded in text (preceded by explanatory text)
  defp find_embedded_json(text) do
    # Look for { or [ that might be JSON
    case Regex.run(~r/[\{\[]/, text, return: :index) do
      [{start, _}] ->
        substring = String.slice(text, start..-1//1)

        if String.starts_with?(substring, "{") do
          extract_json_object(substring)
        else
          extract_json_array(substring)
        end

      nil ->
        {:error, :no_json_found}
    end
  end

  # Find the matching closing bracket, accounting for nesting and strings
  defp find_matching_bracket(text, open_char, close_char) do
    chars = String.to_charlist(text)
    find_matching_bracket(chars, open_char, close_char, 0, false, false, [])
  end

  defp find_matching_bracket([], _open, _close, _depth, _in_string, _escaped, _acc) do
    :error
  end

  defp find_matching_bracket([char | rest], open, close, depth, in_string, escaped, acc) do
    cond do
      # Handle escape sequences in strings
      escaped ->
        find_matching_bracket(rest, open, close, depth, in_string, false, [char | acc])

      # Backslash starts escape sequence in strings
      in_string and char == ?\\ ->
        find_matching_bracket(rest, open, close, depth, in_string, true, [char | acc])

      # Quote toggles string state
      char == ?" ->
        new_in_string = not in_string
        find_matching_bracket(rest, open, close, depth, new_in_string, false, [char | acc])

      # Opening bracket (not in string)
      not in_string and char == open ->
        new_depth = depth + 1
        find_matching_bracket(rest, open, close, new_depth, in_string, false, [char | acc])

      # Closing bracket (not in string)
      not in_string and char == close ->
        new_depth = depth - 1

        if new_depth == 0 do
          # Found matching bracket
          result = [char | acc] |> Enum.reverse() |> List.to_string()
          {:ok, result}
        else
          find_matching_bracket(rest, open, close, new_depth, in_string, false, [char | acc])
        end

      # Any other character
      true ->
        find_matching_bracket(rest, open, close, depth, in_string, false, [char | acc])
    end
  end

  # Decode JSON string, converting Jason errors to our error format
  defp decode_json(json_string) do
    case Jason.decode(json_string) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, :invalid_json}
    end
  end
end
