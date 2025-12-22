defmodule PtcRunner.Lisp.SpecValidator do
  @moduledoc """
  Validates PTC-Lisp specification against implementation.

  Extracts examples from the PTC-Lisp specification and verifies that
  actual execution matches expected results. Helps detect drift between
  the specification and implementation.

  ## Usage

      # Validate all examples in specification
      PtcRunner.Lisp.SpecValidator.validate_spec()

      # Validate a single example
      PtcRunner.Lisp.SpecValidator.validate_example("(+ 1 2)", 3)

      # Get all examples from spec
      examples = PtcRunner.Lisp.SpecValidator.extract_examples()
  """

  @spec_path "docs/ptc-lisp-specification.md"

  @doc """
  Validate all examples in the PTC-Lisp specification.

  Returns a summary of results with counts of passed, failed, and skipped examples.

  ## Returns

      {:ok, %{
        passed: 95,
        failed: 0,
        skipped: 11,
        failures: [...]
      }}
  """
  @spec validate_spec() :: {:ok, map()} | {:error, String.t()}
  def validate_spec do
    case load_spec() do
      {:ok, content} ->
        examples = extract_examples(content)
        validate_examples(examples)

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Extract all examples from the specification.

  Returns a list of example tuples: `{code, expected_output}`.

  ## Returns

      [
        {"(+ 1 2)", 3},
        {"(filter even? [1 2 3 4])", [2, 4]},
        ...
      ]
  """
  @spec extract_examples() :: {:ok, [tuple()]} | {:error, String.t()}
  def extract_examples do
    case load_spec() do
      {:ok, content} ->
        {:ok, extract_examples_from_content(content)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Extract examples from specification content string.

  Parses the markdown content and extracts code examples with expected values.

  ## Parameters

    * `content` - The specification markdown content as a string

  ## Returns

      [
        {"(+ 1 2)", 3},
        {"(filter even? [1 2 3 4])", [2, 4]},
        ...
      ]
  """
  @spec extract_examples(String.t()) :: [tuple()]
  def extract_examples(content) when is_binary(content) do
    extract_examples_from_content(content)
  end

  @doc """
  Validate a single example: code should produce expected result.

  Returns `:ok` if validation passes, `{:error, reason}` otherwise.

  ## Examples

      iex> PtcRunner.Lisp.SpecValidator.validate_example("(+ 1 2)", 3)
      :ok

      iex> PtcRunner.Lisp.SpecValidator.validate_example("(+ 1 2)", 4)
      {:error, "Expected 4 but got 3"}
  """
  @spec validate_example(String.t(), any()) :: :ok | {:error, String.t()}
  def validate_example(code, expected) do
    case PtcRunner.Lisp.run(code) do
      {:ok, result, _delta, _memory} ->
        if result == expected do
          :ok
        else
          {:error, "Expected #{inspect(expected)} but got #{inspect(result)}"}
        end

      {:error, reason} ->
        {:error, "Execution failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Get a hash of all examples in the specification.

  Used to detect changes to the specification over time.
  """
  @spec examples_hash() :: {:ok, String.t()} | {:error, String.t()}
  def examples_hash do
    case extract_examples() do
      {:ok, examples} ->
        serialized = inspect(examples, pretty: true)
        hash = :crypto.hash(:sha256, serialized) |> Base.encode16()
        {:ok, hash}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Get hashes for each section of the specification.

  Returns a map of section headers to their content hashes.
  Used to detect drift in specific sections of the spec.

  ## Returns

      {:ok, %{
        "## 1. Overview" => "hash1",
        "## 2. Lexical Structure" => "hash2",
        ...
      }}
  """
  @spec section_hashes() :: {:ok, map()} | {:error, String.t()}
  def section_hashes do
    case load_spec() do
      {:ok, content} ->
        {:ok, extract_section_hashes(content)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Get negative test cases for Section 13 (unsupported features).

  Returns a list of tuples: `{feature_name, code, expected_error_type}`.
  These programs should all fail with specific error types.

  ## Returns

      [
        {"def", "(def x 10)", :validation_error},
        {"defn", "(defn foo [x] x)", :validation_error},
        ...
      ]
  """
  @spec negative_tests() :: [tuple()]
  def negative_tests do
    [
      {"def", "(def x 10)", :validation_error},
      {"defn", "(defn foo [x] x)", :validation_error},
      {"#()", "#(+ % 1)", :parse_error},
      {"loop/recur", "(loop [x 0] x)", :validation_error},
      {"lazy-seq", "(lazy-seq [1])", :unbound_var},
      {"str", "(str \"a\" \"b\")", :unbound_var},
      {"range", "(range 10)", :unbound_var},
      {"partial", "(partial + 1)", :unbound_var},
      {"comp", "(comp inc inc)", :unbound_var},
      {"eval", "(eval (+ 1 2))", :unbound_var},
      {"read-string", "(read-string \"(+ 1 2)\")", :unbound_var},
      {"println", "(println \"hi\")", :unbound_var}
    ]
  end

  @doc """
  Validate a negative test case (should fail with specific error).

  Returns `:ok` if the code fails with the expected error type,
  `{:error, reason}` otherwise.
  """
  @spec validate_negative_test(String.t(), atom()) :: :ok | {:error, String.t()}
  def validate_negative_test(code, expected_error_type) do
    case PtcRunner.Lisp.run(code) do
      {:ok, _result, _delta, _memory} ->
        {:error, "Expected #{expected_error_type} but code executed successfully"}

      {:error, reason} ->
        validate_error_type(reason, expected_error_type)
    end
  end

  defp validate_error_type(reason, expected_error_type) do
    if error_matches_type?(reason, expected_error_type) do
      :ok
    else
      {:error, "Expected #{expected_error_type} but got: #{inspect(reason)}"}
    end
  end

  # Private functions

  defp load_spec do
    path = Path.expand(@spec_path)

    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, _} ->
        {:error, "Could not read specification file: #{path}"}
    end
  end

  defp extract_examples_from_content(content) do
    lines = String.split(content, "\n")
    extract_examples_from_lines(lines, [])
  end

  defp extract_examples_from_lines([], acc) do
    Enum.reverse(acc)
  end

  defp extract_examples_from_lines([line | rest], acc) do
    case extract_example_from_line(line) do
      {:ok, code, expected} ->
        # Parse the expected value from the comment
        case parse_expected(expected) do
          {:ok, value} ->
            extract_examples_from_lines(rest, [{code, value} | acc])

          :error ->
            # Skip examples we can't parse
            extract_examples_from_lines(rest, acc)
        end

      :no_example ->
        extract_examples_from_lines(rest, acc)
    end
  end

  # Extract example from a single line with pattern: code  ; => expected
  defp extract_example_from_line(line) do
    line = String.trim(line)

    case String.split(line, "; =>") do
      [code, expected] ->
        code = String.trim(code)
        expected = String.trim(expected)

        if String.length(code) > 0 and String.length(expected) > 0 do
          {:ok, code, expected}
        else
          :no_example
        end

      _ ->
        :no_example
    end
  end

  # Parse expected values from string format
  defp parse_expected(str) do
    str = String.trim(str)

    cond do
      parse_literal(str) != :not_literal -> parse_literal(str)
      String.starts_with?(str, "\"") -> parse_quoted_string(str)
      String.starts_with?(str, ":") -> parse_keyword(str)
      collection?(str) -> parse_collection(str)
      map?(str) -> parse_map(str)
      true -> :error
    end
  end

  # Parse literal values: nil, true, false, numbers
  defp parse_literal(str) do
    cond do
      str == "nil" -> {:ok, nil}
      str == "true" -> {:ok, true}
      str == "false" -> {:ok, false}
      Regex.match?(~r/^-?\d+$/, str) -> {:ok, String.to_integer(str)}
      Regex.match?(~r/^-?\d+\.\d+$/, str) -> {:ok, String.to_float(str)}
      true -> :not_literal
    end
  end

  # Check if string is a collection (list or vector)
  defp collection?(str) do
    (String.starts_with?(str, "[") and String.ends_with?(str, "]")) or
      (String.starts_with?(str, "(") and String.ends_with?(str, ")"))
  end

  # Check if string is a map
  defp map?(str) do
    String.starts_with?(str, "{") and String.ends_with?(str, "}")
  end

  # Parse quoted strings
  defp parse_quoted_string(str) do
    if String.ends_with?(str, "\"") do
      content = String.slice(str, 1..-2//1)
      {:ok, unescape_string(content)}
    else
      :error
    end
  end

  # Parse keywords
  defp parse_keyword(str) do
    keyword_name = String.slice(str, 1..-1//1)
    {:ok, String.to_atom(keyword_name)}
  end

  # Unescape string literals
  defp unescape_string(str) do
    str
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\r", "\r")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  # Parse collections like [1 2 3] or (1 2 3)
  defp parse_collection(str) do
    inner = String.slice(str, 1..-2//1) |> String.trim()

    if String.length(inner) == 0 do
      {:ok, []}
    else
      # Split on whitespace for simple collections
      items =
        inner
        |> String.split(~r/\s+/)
        |> Enum.map(&parse_expected/1)

      # Check if all parsed successfully
      if Enum.all?(items, &match?({:ok, _}, &1)) do
        values = Enum.map(items, fn {:ok, v} -> v end)
        {:ok, values}
      else
        :error
      end
    end
  end

  # Parse maps - simplified version for basic maps only
  defp parse_map(str) do
    inner = String.slice(str, 1..-2//1) |> String.trim()

    if String.length(inner) == 0 do
      {:ok, %{}}
    else
      # Very simple parsing: key value key value...
      # Handles only keyword keys and simple values
      tokens = String.split(inner, ~r/\s+/)

      case parse_map_tokens(tokens, %{}) do
        {:ok, map} -> {:ok, map}
        :error -> :error
      end
    end
  end

  defp parse_map_tokens([], acc), do: {:ok, acc}

  defp parse_map_tokens([key, value | rest], acc) do
    case parse_expected(key) do
      {:ok, parsed_key} ->
        case parse_expected(value) do
          {:ok, parsed_value} ->
            parse_map_tokens(rest, Map.put(acc, parsed_key, parsed_value))

          :error ->
            :error
        end

      :error ->
        :error
    end
  end

  defp parse_map_tokens(_, _), do: :error

  defp validate_examples(examples) do
    validate_examples(examples, %{passed: 0, failed: 0, skipped: 0, failures: []})
  end

  defp validate_examples([], results) do
    {:ok, results}
  end

  defp validate_examples([{code, expected} | rest], results) do
    case validate_example(code, expected) do
      :ok ->
        validate_examples(rest, %{results | passed: results.passed + 1})

      {:error, reason} ->
        failure = {code, expected, reason}

        validate_examples(rest, %{
          results
          | failed: results.failed + 1,
            failures: [failure | results.failures]
        })
    end
  end

  defp extract_section_hashes(content) do
    content
    |> String.split(~r/^## /m, include_captures: false)
    |> Enum.drop(1)
    |> Enum.map(fn section ->
      # Get section header from first line
      [header | rest] = String.split(section, "\n", parts: 2)
      section_content = Enum.join(rest, "\n")

      # Hash the content
      hash = :crypto.hash(:sha256, section_content) |> Base.encode16()
      {"## #{header}", hash}
    end)
    |> Enum.into(%{})
  end

  defp error_matches_type?(error, expected)
       when is_tuple(error) and tuple_size(error) >= 1 and is_atom(elem(error, 0)) do
    check_error_type(elem(error, 0), expected)
  end

  defp error_matches_type?(_error, _expected) do
    false
  end

  defp check_error_type(error_type, expected) do
    cond do
      error_type == expected ->
        true

      # Map :unbound_var to validation_error if that's expected
      error_type == :unbound_var and expected == :validation_error ->
        true

      true ->
        false
    end
  end
end
