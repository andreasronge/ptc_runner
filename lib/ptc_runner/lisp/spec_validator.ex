defmodule PtcRunner.Lisp.SpecValidator do
  @moduledoc """
  Validates PTC-Lisp specification against implementation.

  Reads `docs/ptc-lisp-specification.md`, asks
  `PtcRunner.Lisp.SpecValidator.Parser` to extract `; =>` examples
  from the markdown, then runs each example through
  `PtcRunner.Lisp.run/2` and reports per-section pass/fail counts plus
  `TODO`/`BUG` markers. Helps detect drift between the specification
  and the implementation.

  The markdown-parsing half lives in
  `PtcRunner.Lisp.SpecValidator.Parser` (#899). This module is the
  thin orchestration façade: spec I/O + example execution + result
  aggregation + negative-test handling.

  ## Usage

      # Validate all examples in specification
      PtcRunner.Lisp.SpecValidator.validate_spec()

      # Validate a single example
      PtcRunner.Lisp.SpecValidator.validate_example("(+ 1 2)", 3)

      # Get all examples from spec
      examples = PtcRunner.Lisp.SpecValidator.extract_examples()
  """

  alias PtcRunner.Lisp.SpecValidator.Parser

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
        extracted = Parser.extract_examples(content)
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
        {:ok, Parser.extract_examples(content)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Extract examples from specification content string.

  Parses the markdown content and extracts code examples with expected values,
  TODO markers, BUG markers, and counts skipped illustrative examples.

  Delegates to `PtcRunner.Lisp.SpecValidator.Parser.extract_examples/1`.

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
  defdelegate extract_examples(content), to: Parser

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
    opts =
      if String.contains?(code, "budget/remaining") do
        [budget: mock_budget()]
      else
        []
      end

    case PtcRunner.Lisp.run(code, opts) do
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
        {:ok, Parser.extract_section_hashes(content)}

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
        {"lazy-seq", "(lazy-seq [1])", :unbound_var},
        {"eval", "(eval (+ 1 2))", :unbound_var},
        ...
      ]
  """
  @spec negative_tests() :: [tuple()]
  def negative_tests do
    # Only features that remain unsupported per Section 13
    # Removed: def, defn, #(), loop/recur, str, println, partial, comp (now supported)
    [
      {"lazy-seq", "(lazy-seq [1])", :unbound_var},
      {"eval", "(eval (+ 1 2))", :unbound_var},
      {"read-string", "(read-string \"(+ 1 2)\")", :unbound_var},
      {"try", "(try 1)", :unbound_var}
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

  # ============================================================
  # Private — spec loading
  # ============================================================

  defp load_spec do
    path = Path.expand(@spec_path)

    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, _} ->
        {:error, "Could not read specification file: #{path}"}
    end
  end

  # Mock budget for spec validation of budget/remaining examples.
  # Values match expected results in the specification.
  defp mock_budget do
    %{
      "work-turns" => 10,
      "retry-turns" => 5,
      "tokens" => %{"cache-read" => 2000}
    }
  end

  # ============================================================
  # Private — example execution / aggregation
  # ============================================================

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

    # Each example runs in its own sandbox process, so they parallelize cleanly.
    # Keep `ordered: true` so `failures` ordering is deterministic.
    results =
      examples
      |> Task.async_stream(
        fn {code, expected, section} ->
          {validate_example(code, expected), code, expected, section}
        end,
        ordered: true,
        timeout: 30_000,
        max_concurrency: System.schedulers_online(),
        on_timeout: :kill_task
      )
      |> Enum.reduce(initial_results, &fold_example_result/2)

    {:ok, results}
  end

  defp fold_example_result({:ok, {:ok, _code, _expected, section}}, results) do
    %{
      results
      | passed: results.passed + 1,
        by_section: update_section_stats(results.by_section, section, :pass)
    }
  end

  defp fold_example_result({:ok, {{:error, reason}, code, expected, section}}, results) do
    %{
      results
      | failed: results.failed + 1,
        failures: [{code, expected, reason, section} | results.failures],
        by_section: update_section_stats(results.by_section, section, :fail)
    }
  end

  defp fold_example_result({:exit, reason}, results) do
    %{
      results
      | failed: results.failed + 1,
        failures: [
          {"<task crashed>", nil, "Task exited: #{inspect(reason)}", "<unknown>"}
          | results.failures
        ],
        by_section: update_section_stats(results.by_section, "<unknown>", :fail)
    }
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

  # ============================================================
  # Private — negative-test error matching
  # ============================================================

  defp validate_error_type(reason, expected_error_type) do
    if error_matches_type?(reason, expected_error_type) do
      :ok
    else
      {:error, "Expected #{expected_error_type} but got: #{inspect(reason)}"}
    end
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
