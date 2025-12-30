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

  Returns a summary of results with counts of passed, failed, skipped examples,
  as well as TODO and BUG markers found in the spec.

  ## Returns

      {:ok, %{
        passed: 95,
        failed: 0,
        skipped: 2,
        todos: [{"(code)", "description", "## Section"}, ...],
        bugs: [],
        failures: [...]
      }}
  """
  @spec validate_spec() :: {:ok, map()} | {:error, String.t()}
  def validate_spec do
    case load_spec() do
      {:ok, content} ->
        extracted = extract_examples(content)
        validate_examples(extracted)

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Extract all examples from the specification.

  Returns a map with categorized examples:
  - `examples` - Testable examples as `{code, expected, section}` tuples
  - `todos` - TODO markers as `{code, description, section}` tuples
  - `bugs` - BUG markers as `{code, description, section}` tuples
  - `skipped` - Count of illustrative examples (using `...`)

  ## Returns

      {:ok, %{
        examples: [{"(+ 1 2)", 3, "## Section"}, ...],
        todos: [{"(code)", "description", "## Section"}, ...],
        bugs: [],
        skipped: 2
      }}
  """
  @spec extract_examples() :: {:ok, map()} | {:error, String.t()}
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

  Parses the markdown content and extracts code examples with expected values,
  TODO markers, BUG markers, and counts skipped illustrative examples.

  ## Parameters

    * `content` - The specification markdown content as a string

  ## Returns

      %{
        examples: [{"(+ 1 2)", 3, "## Section"}, ...],
        todos: [{"(code)", "description", "## Section"}, ...],
        bugs: [],
        skipped: 2
      }
  """
  @spec extract_examples(String.t()) :: map()
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
      {:ok, %{return: result}} ->
        if result == expected do
          :ok
        else
          {:error, "Expected #{inspect(expected)} but got #{inspect(result)}"}
        end

      {:error, %{fail: fail}} ->
        {:error, "Execution failed: #{inspect(fail)}"}
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
      {:ok, _step} ->
        {:error, "Expected #{expected_error_type} but code executed successfully"}

      {:error, %{fail: fail}} ->
        validate_error_type(fail.reason, expected_error_type)
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
    initial_acc = %{examples: [], todos: [], bugs: [], skipped: 0}

    # Pass 1: Extract single-line examples
    single_line_result = extract_examples_from_lines(lines, initial_acc, nil)

    # Pass 2: Assemble multi-line examples
    multi_line_result = extract_multiline_examples(lines, initial_acc, nil)

    # Combine and deduplicate (multiline takes precedence over single-line)
    multiline_codes =
      Enum.map(multi_line_result.examples, fn {code, _, _} -> code end) |> MapSet.new()

    multiline_todo_codes =
      Enum.map(multi_line_result.todos, fn {code, _, _} -> code end) |> MapSet.new()

    multiline_bug_codes =
      Enum.map(multi_line_result.bugs, fn {code, _, _} -> code end) |> MapSet.new()

    all_multiline_codes =
      MapSet.union(multiline_codes, MapSet.union(multiline_todo_codes, multiline_bug_codes))

    filtered_examples =
      Enum.filter(single_line_result.examples, fn {code, _, _} ->
        not MapSet.member?(all_multiline_codes, code)
      end)

    filtered_todos =
      Enum.filter(single_line_result.todos, fn {code, _, _} ->
        not MapSet.member?(all_multiline_codes, code)
      end)

    filtered_bugs =
      Enum.filter(single_line_result.bugs, fn {code, _, _} ->
        not MapSet.member?(all_multiline_codes, code)
      end)

    %{
      examples: filtered_examples ++ multi_line_result.examples,
      todos: filtered_todos ++ multi_line_result.todos,
      bugs: filtered_bugs ++ multi_line_result.bugs,
      skipped: single_line_result.skipped + multi_line_result.skipped
    }
  end

  defp extract_examples_from_lines([], acc, _current_section) do
    %{
      acc
      | examples: Enum.reverse(acc.examples),
        todos: Enum.reverse(acc.todos),
        bugs: Enum.reverse(acc.bugs)
    }
  end

  defp extract_examples_from_lines([line | rest], acc, current_section) do
    # Check if this is a section header
    section = extract_section_header(line)

    if section do
      # Update current section
      extract_examples_from_lines(rest, acc, section)
    else
      # Try to extract example from this line
      case extract_example_from_line(line) do
        {:ok, code, expected} ->
          # Parse the expected value from the comment
          new_acc = accumulate_parsed_example(acc, code, expected, current_section)
          extract_examples_from_lines(rest, new_acc, current_section)

        :no_example ->
          extract_examples_from_lines(rest, acc, current_section)
      end
    end
  end

  # Accumulate parsed example into appropriate category
  defp accumulate_parsed_example(acc, code, expected_str, section) do
    case parse_expected(expected_str) do
      {:ok, value} ->
        %{acc | examples: [{code, value, section} | acc.examples]}

      {:todo, description} ->
        %{acc | todos: [{code, description, section} | acc.todos]}

      {:bug, description} ->
        %{acc | bugs: [{code, description, section} | acc.bugs]}

      :skip ->
        %{acc | skipped: acc.skipped + 1}

      :error ->
        # Unparseable - silently skip
        acc
    end
  end

  defp extract_multiline_examples(lines, acc, current_section) do
    indexed_lines = Enum.with_index(lines)
    extract_multiline_from_indexed(indexed_lines, [], acc, current_section)
  end

  defp extract_multiline_from_indexed([], _indexed_lines, acc, _current_section) do
    %{
      acc
      | examples: Enum.reverse(acc.examples),
        todos: Enum.reverse(acc.todos),
        bugs: Enum.reverse(acc.bugs)
    }
  end

  defp extract_multiline_from_indexed([{line, idx} | rest], indexed_lines, acc, current_section) do
    # Check if this is a section header
    section = extract_section_header(line)

    if section do
      extract_multiline_from_indexed(rest, indexed_lines ++ [{idx, line}], acc, section)
    else
      all_indexed = indexed_lines ++ [{idx, line}]
      process_multiline_candidate(line, idx, rest, all_indexed, acc, current_section)
    end
  end

  defp process_multiline_candidate(line, idx, rest, all_indexed, acc, current_section) do
    line_trimmed = String.trim(line)

    case String.split(line_trimmed, "; =>") do
      [code, expected] ->
        process_multiline_split(code, expected, idx, rest, all_indexed, acc, current_section)

      _ ->
        extract_multiline_from_indexed(rest, all_indexed, acc, current_section)
    end
  end

  defp process_multiline_split(code, expected, idx, rest, all_indexed, acc, current_section) do
    code_only = String.trim(code)
    expected_trimmed = String.trim(expected)

    if String.length(code_only) > 0 and String.length(expected_trimmed) > 0 and
         has_more_closing_than_opening?(code_only) do
      new_acc =
        accumulate_multiline_example(acc, all_indexed, idx, expected_trimmed, current_section)

      extract_multiline_from_indexed(rest, all_indexed, new_acc, current_section)
    else
      extract_multiline_from_indexed(rest, all_indexed, acc, current_section)
    end
  end

  # Accumulate multiline example into appropriate category
  defp accumulate_multiline_example(acc, all_indexed, idx, expected_str, section) do
    case parse_expected(expected_str) do
      {category, value} when category in [:ok, :todo, :bug] ->
        case assemble_multiline_example(all_indexed, idx, section) do
          {:ok, code} ->
            add_to_category(acc, category, code, value, section)

          :not_multiline ->
            acc
        end

      :skip ->
        %{acc | skipped: acc.skipped + 1}

      :error ->
        acc
    end
  end

  # Add code to the appropriate category field
  defp add_to_category(acc, :ok, code, value, section) do
    %{acc | examples: [{code, value, section} | acc.examples]}
  end

  defp add_to_category(acc, :todo, code, description, section) do
    %{acc | todos: [{code, description, section} | acc.todos]}
  end

  defp add_to_category(acc, :bug, code, description, section) do
    %{acc | bugs: [{code, description, section} | acc.bugs]}
  end

  # Core helper for parenthesis balance counting
  # Returns:
  # - Non-negative integer: balance count (open - close), or 0 if balanced
  # - :unbalanced if more closing than opening parens detected
  defp paren_balance(code) do
    code
    |> String.graphemes()
    |> Enum.reduce_while(0, fn char, count ->
      case char do
        "(" -> {:cont, count + 1}
        ")" -> if count > 0, do: {:cont, count - 1}, else: {:halt, :unbalanced}
        _ -> {:cont, count}
      end
    end)
  end

  # Check if code has more closing parens than opening parens
  # Uses reduce without halting to count all parens
  defp has_more_closing_than_opening?(code) do
    result =
      code
      |> String.graphemes()
      |> Enum.reduce(0, fn char, count ->
        case char do
          "(" -> count + 1
          ")" -> count - 1
          _ -> count
        end
      end)

    result < 0
  end

  defp assemble_multiline_example(indexed_lines, end_line_idx, _section) do
    # Get the line at end_line_idx
    case Enum.find(indexed_lines, fn {idx, _} -> idx == end_line_idx end) do
      {_, end_line} ->
        end_line_trimmed = String.trim(end_line)

        # Extract code part (everything before ; =>)
        code_part =
          case String.split(end_line_trimmed, "; =>") do
            [code, _] -> String.trim(code)
            _ -> end_line_trimmed
          end

        # Only try to assemble if the code part has unbalanced parens
        if has_more_closing_than_opening?(code_part) do
          case scan_backwards(indexed_lines, end_line_idx - 1, code_part) do
            {:ok, assembled_code} ->
              {:ok, assembled_code}

            :not_found ->
              :not_multiline
          end
        else
          :not_multiline
        end

      nil ->
        :not_multiline
    end
  end

  defp scan_backwards(indexed_lines, current_idx, accumulated_code) do
    if current_idx < 0 do
      if balanced_parens?(accumulated_code) do
        {:ok, accumulated_code}
      else
        :not_found
      end
    else
      case Enum.find(indexed_lines, fn {idx, _} -> idx == current_idx end) do
        {_, line} ->
          process_backward_line(indexed_lines, current_idx, accumulated_code, line)

        nil ->
          scan_backwards(indexed_lines, current_idx - 1, accumulated_code)
      end
    end
  end

  defp process_backward_line(indexed_lines, current_idx, accumulated_code, line) do
    line = String.trim(line)

    if String.length(line) == 0 do
      scan_backwards(indexed_lines, current_idx - 1, accumulated_code)
    else
      check_backward_line_type(indexed_lines, current_idx, accumulated_code, line)
    end
  end

  defp check_backward_line_type(indexed_lines, current_idx, accumulated_code, line) do
    cond do
      String.contains?(line, "; =>") ->
        :not_found

      String.starts_with?(line, ";") ->
        scan_backwards(indexed_lines, current_idx - 1, accumulated_code)

      true ->
        process_code_line(indexed_lines, current_idx, accumulated_code, line)
    end
  end

  defp process_code_line(indexed_lines, current_idx, accumulated_code, line) do
    # Remove trailing comments
    line_without_comment =
      case String.split(line, ";", parts: 2) do
        [code, _comment] -> String.trim_trailing(code)
        _ -> line
      end

    new_accumulated = line_without_comment <> "\n" <> accumulated_code

    if balanced_parens?(new_accumulated) do
      {:ok, new_accumulated}
    else
      scan_backwards(indexed_lines, current_idx - 1, new_accumulated)
    end
  end

  # Check if code has balanced parentheses
  defp balanced_parens?(code) do
    paren_balance(code) == 0
  end

  # Extract section header from line (pattern: ## N. Title)
  defp extract_section_header(line) do
    line = String.trim(line)

    if String.match?(line, ~r/^##\s+\d+\./) do
      line
    else
      nil
    end
  end

  # Extract example from a single line with pattern: code  ; => expected
  # Returns:
  # - {:ok, code, expected} - example found
  # - :no_example - no example on this line
  defp extract_example_from_line(line) do
    line = String.trim(line)

    case String.split(line, "; =>") do
      [code, expected] ->
        code = String.trim(code)
        expected = String.trim(expected)

        if String.length(code) > 0 and String.length(expected) > 0 do
          # Check if this is a fragment (incomplete expression)
          if fragment?(code) do
            :no_example
          else
            {:ok, code, expected}
          end
        else
          :no_example
        end

      _ ->
        :no_example
    end
  end

  # Detect if a code string is a fragment (incomplete expression)
  # Fragments are lines that end with ) but are not complete expressions
  # Examples: "name)", "age)", "x))", "(* x y))"
  defp fragment?(code) do
    code = String.trim(code)

    # A fragment is something that:
    # 1. Ends with one or more )
    # 2. Is not a complete, balanced expression
    cond do
      not String.ends_with?(code, ")") ->
        false

      # Simple cases: just identifiers with closing parens (e.g., "name)", "age)", "the-name)")
      String.match?(code, ~r/^[\w\-]+\)+$/) ->
        true

      # Cases like "(* x y))" - has unbalanced parentheses
      has_unbalanced_parens?(code) ->
        true

      true ->
        false
    end
  end

  # Check if a code string has unbalanced parentheses
  # Returns true if there are more closing parens than opening parens at any point
  defp has_unbalanced_parens?(code) do
    paren_balance(code) == :unbalanced
  end

  # Parse expected values from string format
  # Returns:
  #   {:ok, value} - parseable expected value
  #   {:todo, description} - TODO marker (feature not implemented)
  #   {:bug, description} - BUG marker (known bug)
  #   :skip - illustrative example (e.g., "...")
  #   :error - unparseable value
  defp parse_expected(str) do
    str = String.trim(str)

    cond do
      # Semantic markers for doc tests
      String.starts_with?(str, "TODO") -> parse_marker(str, :todo)
      String.starts_with?(str, "BUG") -> parse_marker(str, :bug)
      str == "..." -> :skip
      # Regular expected values
      parse_literal(str) != :not_literal -> parse_literal(str)
      String.starts_with?(str, "\"") -> parse_quoted_string(str)
      String.starts_with?(str, ":") -> parse_keyword(str)
      collection?(str) -> parse_collection(str)
      map?(str) -> parse_map(str)
      true -> :error
    end
  end

  # Parse TODO or BUG markers with optional description
  # Formats: "TODO", "TODO: description", "BUG", "BUG: description"
  defp parse_marker(str, type) do
    marker = if type == :todo, do: "TODO", else: "BUG"

    description =
      case String.split(str, ":", parts: 2) do
        [^marker, desc] -> String.trim(desc)
        [^marker] -> ""
        _ -> ""
      end

    {type, description}
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

  defp validate_examples(%{examples: examples, todos: todos, bugs: bugs, skipped: skipped}) do
    initial_results = %{
      passed: 0,
      failed: 0,
      skipped: skipped,
      todos: todos,
      bugs: bugs,
      failures: [],
      by_section: %{}
    }

    validate_example_list(examples, initial_results)
  end

  defp validate_example_list([], results) do
    {:ok, results}
  end

  defp validate_example_list([{code, expected, section} | rest], results) do
    case validate_example(code, expected) do
      :ok ->
        # Update section stats
        by_section = update_section_stats(results.by_section, section, :pass)

        validate_example_list(rest, %{
          results
          | passed: results.passed + 1,
            by_section: by_section
        })

      {:error, reason} ->
        failure = {code, expected, reason, section}

        # Update section stats
        by_section = update_section_stats(results.by_section, section, :fail)

        validate_example_list(rest, %{
          results
          | failed: results.failed + 1,
            failures: [failure | results.failures],
            by_section: by_section
        })
    end
  end

  defp update_section_stats(by_section, section, status) do
    current = Map.get(by_section, section, %{passed: 0, failed: 0})

    updated =
      case status do
        :pass -> %{current | passed: current.passed + 1}
        :fail -> %{current | failed: current.failed + 1}
      end

    Map.put(by_section, section, updated)
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

  # New format: error reason is an atom from Step.fail.reason
  defp error_matches_type?(error, expected) when is_atom(error) do
    check_error_type(error, expected)
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
