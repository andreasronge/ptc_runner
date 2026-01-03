defmodule PtcDemo.TestRunner.Base do
  @moduledoc """
  Shared test runner functionality for both JSON and Lisp DSLs.

  Provides constraint checking, formatting helpers, validation, and summary building
  functions used by both test runners.
  """

  # Constraint checking functions

  @doc """
  Check if a value matches the expected type.

  Returns true if the value is of the expected type, or true for unknown types.

  Supported types:
    - `:integer` - checks if value is an integer
    - `:number` - checks if value is a number (integer or float)
    - `:list` - checks if value is a list
    - `:string` - checks if value is a binary string
    - `:map` - checks if value is a map
    - Other types return true (no validation)

  ## Examples

      iex> PtcDemo.TestRunner.Base.check_type(42, :integer)
      true

      iex> PtcDemo.TestRunner.Base.check_type(42.5, :integer)
      false

      iex> PtcDemo.TestRunner.Base.check_type(42.5, :number)
      true
  """
  @spec check_type(any(), atom()) :: boolean()
  def check_type(value, :integer), do: is_integer(value)
  def check_type(value, :number), do: is_number(value)
  def check_type(value, :list), do: is_list(value)
  def check_type(value, :string), do: is_binary(value)
  def check_type(value, :map), do: is_map(value)
  def check_type(_value, _), do: true

  @doc """
  Check if a value satisfies a constraint.

  Returns true if the value passes the constraint, or an error message string if it fails.

  Supported constraints:
    - `{:eq, expected}` - value equals expected
    - `{:gt, min}` - value greater than min
    - `{:gte, min}` - value greater than or equal to min
    - `{:lt, max}` - value less than max
    - `{:between, min, max}` - value between min and max (inclusive)
    - `{:length, expected}` - list has expected length
    - `{:starts_with, prefix}` - string starts with prefix
    - `{:has_keys, keys}` - map has all specified keys
    - Other constraints return true (no validation)

  ## Examples

      iex> PtcDemo.TestRunner.Base.check_constraint(500, {:eq, 500})
      true

      iex> PtcDemo.TestRunner.Base.check_constraint(499, {:eq, 500})
      "Expected 500, got 499"

      iex> PtcDemo.TestRunner.Base.check_constraint(50, {:between, 1, 100})
      true

      iex> PtcDemo.TestRunner.Base.check_constraint(101, {:between, 1, 100})
      "Expected between 1-100, got 101"
  """
  @spec check_constraint(any(), tuple() | any()) :: boolean() | String.t()
  def check_constraint(value, {:eq, expected}) do
    if value == expected, do: true, else: "Expected #{inspect(expected)}, got #{inspect(value)}"
  end

  def check_constraint(value, {:gt, min}) do
    if value > min, do: true, else: "Expected > #{min}, got #{inspect(value)}"
  end

  def check_constraint(value, {:gte, min}) do
    if value >= min, do: true, else: "Expected >= #{min}, got #{inspect(value)}"
  end

  def check_constraint(value, {:lt, max}) do
    if value < max, do: true, else: "Expected < #{max}, got #{inspect(value)}"
  end

  def check_constraint(value, {:between, min, max}) do
    if value >= min and value <= max do
      true
    else
      "Expected between #{min}-#{max}, got #{inspect(value)}"
    end
  end

  def check_constraint(value, {:length, expected}) when is_list(value) do
    actual = length(value)
    if actual == expected, do: true, else: "Expected length #{expected}, got #{actual}"
  end

  def check_constraint(value, {:starts_with, prefix}) when is_binary(value) do
    if String.starts_with?(value, prefix) do
      true
    else
      "Expected to start with '#{prefix}', got '#{value}'"
    end
  end

  def check_constraint(value, {:one_of, options}) when is_list(options) do
    if value in options do
      true
    else
      "Expected one of #{inspect(options)}, got #{inspect(value)}"
    end
  end

  def check_constraint(value, {:has_keys, keys}) when is_map(value) and is_list(keys) do
    missing = Enum.filter(keys, fn key -> not Map.has_key?(value, key) end)

    if missing == [] do
      true
    else
      "Expected keys #{inspect(keys)}, missing #{inspect(missing)}"
    end
  end

  def check_constraint(_value, _), do: true

  # Formatting helpers

  @doc """
  Format a cost value as a string with currency symbol.

  Returns a formatted string like "$1.2500" for valid costs, or "$0.00" otherwise.

  ## Examples

      iex> PtcDemo.TestRunner.Base.format_cost(1.25)
      "$1.2500"

      iex> PtcDemo.TestRunner.Base.format_cost(0.0)
      "$0.00"

      iex> PtcDemo.TestRunner.Base.format_cost(nil)
      "$0.00"
  """
  @spec format_cost(any()) :: String.t()
  def format_cost(cost) when is_float(cost) and cost > 0 do
    "$#{:erlang.float_to_binary(cost, decimals: 4)}"
  end

  def format_cost(_), do: "$0.00"

  @doc """
  Format a duration in milliseconds as a human-readable string.

  Returns a string like "500ms", "1.5s", or "2.3m" depending on magnitude.

  ## Examples

      iex> PtcDemo.TestRunner.Base.format_duration(500)
      "500ms"

      iex> PtcDemo.TestRunner.Base.format_duration(1500)
      "1.5s"

      iex> PtcDemo.TestRunner.Base.format_duration(120000)
      "2.0m"
  """
  @spec format_duration(integer()) :: String.t()
  def format_duration(ms) when ms < 1000, do: "#{ms}ms"
  def format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  def format_duration(ms), do: "#{Float.round(ms / 60_000, 1)}m"

  @doc """
  Format a test attempt result as a truncated string.

  Handles both error tuples and other values, truncating to 50 characters.

  ## Examples

      iex> PtcDemo.TestRunner.Base.format_attempt_result({:error, "Something went wrong"})
      "ERROR: Something went wrong"

      iex> PtcDemo.TestRunner.Base.format_attempt_result(42)
      "42"
  """
  @spec format_attempt_result(any()) :: String.t()
  def format_attempt_result({:error, msg}), do: "ERROR: #{truncate(to_string(msg), 50)}"
  def format_attempt_result(result), do: truncate(inspect(result), 50)

  @doc """
  Truncate a string to a maximum length, appending "..." if truncated.

  Normalizes whitespace by collapsing multiple spaces into single spaces.

  ## Examples

      iex> PtcDemo.TestRunner.Base.truncate("Hello", 10)
      "Hello"

      iex> PtcDemo.TestRunner.Base.truncate("Hello world this is long", 15)
      "Hello world thi..."

      iex> PtcDemo.TestRunner.Base.truncate("Hello  world", 20)
      "Hello world"
  """
  @spec truncate(String.t() | any(), non_neg_integer()) :: String.t()
  def truncate(str, max_len) when is_binary(str) do
    str = String.replace(str, ~r/\s+/, " ") |> String.trim()

    if String.length(str) > max_len do
      String.slice(str, 0, max_len) <> "..."
    else
      str
    end
  end

  def truncate(other, max_len), do: truncate(inspect(other), max_len)

  @doc """
  Get a human-readable type name for a value.

  Returns:
    - `:integer` - for integers
    - `:float` - for floats
    - `:string` - for binary strings
    - `:list` - for lists
    - `:map` - for maps
    - `:boolean` - for booleans
    - `nil` - for nil values
    - `:unknown` - for other types

  ## Examples

      iex> PtcDemo.TestRunner.Base.type_of(42)
      :integer

      iex> PtcDemo.TestRunner.Base.type_of(42.5)
      :float

      iex> PtcDemo.TestRunner.Base.type_of("hello")
      :string

      iex> PtcDemo.TestRunner.Base.type_of(nil)
      nil
  """
  @spec type_of(any()) :: atom()
  def type_of(v) when is_integer(v), do: :integer
  def type_of(v) when is_float(v), do: :float
  def type_of(v) when is_binary(v), do: :string
  def type_of(v) when is_list(v), do: :list
  def type_of(v) when is_map(v), do: :map
  def type_of(v) when is_boolean(v), do: :boolean
  def type_of(nil), do: nil
  def type_of(_), do: :unknown

  # Validation

  @doc """
  Validate a result against a test case's type and constraint.

  Returns a map with:
    - `passed: true | false` - whether validation succeeded
    - `error: String.t()` - error message if validation failed
    - `value: any()` - the validated value if successful

  ## Examples

      iex> PtcDemo.TestRunner.Base.validate_result(500, %{expect: :integer, constraint: {:eq, 500}})
      %{passed: true, value: 500}

      iex> PtcDemo.TestRunner.Base.validate_result(499, %{expect: :integer, constraint: {:eq, 500}})
      %{passed: false, error: "Expected 500, got 499"}

      iex> PtcDemo.TestRunner.Base.validate_result("string", %{expect: :integer, constraint: nil})
      %{passed: false, error: "Wrong type: got \\"string\\" (:string), expected :integer"}
  """
  @spec validate_result(any(), map()) :: map()
  def validate_result(value, test_case) do
    type_ok = check_type(value, test_case.expect)
    constraint_result = check_constraint(value, test_case.constraint)

    cond do
      not type_ok ->
        %{
          passed: false,
          error:
            "Wrong type: got #{inspect(value)} (#{type_of(value)}), expected #{test_case.expect}"
        }

      constraint_result != true ->
        %{
          passed: false,
          error: constraint_result
        }

      true ->
        %{passed: true, value: value}
    end
  end

  # Summary building

  @doc """
  Build a summary map from test results and metadata.

  Aggregates results into counts and statistics for display and reporting.

  ## Parameters

    - `results` - list of test result maps
    - `start_time` - monotonic time in milliseconds when tests started
    - `model` - model name string
    - `data_mode` - data mode atom (e.g., `:schema`)
    - `stats` - stats map with `:total_tokens` and `:total_cost`

  ## Returns

  A map containing aggregated statistics and the full results list.

  ## Example

      results = [
        %{passed: true, attempts: 1},
        %{passed: false, attempts: 3}
      ]

      summary = PtcDemo.TestRunner.Base.build_summary(
        results,
        System.monotonic_time(:millisecond),
        "claude-3-5-haiku",
        :schema,
        %{total_tokens: 1000, total_cost: 0.5}
      )

      iex> summary.passed
      1

      iex> summary.failed
      1

      iex> summary.total
      2
  """
  @spec build_summary(list(), integer(), String.t(), atom(), map()) :: map()
  def build_summary(results, start_time, model, data_mode, stats) do
    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    passed = Enum.count(results, & &1.passed)
    failed = Enum.count(results, &(!&1.passed))
    total = length(results)
    total_attempts = Enum.sum(Enum.map(results, & &1.attempts))

    # Apply cost fallback if needed
    stats_with_fallback = apply_cost_fallback(stats, model)

    %{
      passed: passed,
      failed: failed,
      total: total,
      total_attempts: total_attempts,
      duration_ms: duration_ms,
      model: model,
      data_mode: data_mode,
      results: results,
      stats: stats_with_fallback,
      timestamp: DateTime.utc_now(),
      version: get_ptc_runner_version(),
      commit: get_git_commit()
    }
  end

  defp apply_cost_fallback(stats, model) do
    case stats do
      %{total_cost: cost} when cost == nil or cost == 0.0 ->
        # Calculate cost from tokens if not provided by API
        calculated_cost =
          LLMClient.calculate_cost(
            model,
            Map.get(stats, :input_tokens, 0),
            Map.get(stats, :output_tokens, 0)
          )

        %{stats | total_cost: calculated_cost}

      _ ->
        stats
    end
  end

  @doc """
  Print a test summary to stdout.

  Displays pass/fail counts, duration, model, token usage, and cost.

  ## Example

      summary = %{
        passed: 18,
        failed: 2,
        total: 20,
        total_attempts: 45,
        duration_ms: 5000,
        model: "claude-3-5-haiku",
        stats: %{total_tokens: 10000, total_cost: 0.25}
      }

      PtcDemo.TestRunner.Base.print_summary(summary)
      # Prints to stdout
  """
  @spec print_summary(map()) :: :ok
  def print_summary(summary) do
    IO.puts("\n" <> String.duplicate("=", 50))
    IO.puts("Results: #{summary.passed}/#{summary.total} passed, #{summary.failed} failed")

    IO.puts(
      "Total attempts: #{summary.total_attempts} (#{Float.round(summary.total_attempts / summary.total, 1)} avg per test)"
    )

    IO.puts("Duration: #{format_duration(summary.duration_ms)}")
    IO.puts("Model: #{summary.model}")
    IO.puts(String.duplicate("=", 50))

    IO.puts(
      "\nToken usage: #{summary.stats.total_tokens} tokens, cost: #{format_cost(summary.stats.total_cost)}"
    )

    :ok
  end

  @doc """
  Print details of failed tests to stdout.

  Displays error messages, attempts, and all programs tried for each failed test.

  ## Example

      results = [
        %{
          index: 1,
          query: "How many products?",
          error: "Expected 500, got 499",
          attempts: 2,
          all_programs: [
            {"(count products)", {:ok, 499}},
            {"(count all products)", {:error, "undefined"}}
          ]
        }
      ]

      PtcDemo.TestRunner.Base.print_failed_tests(results)
      # Prints to stdout
  """
  @spec print_failed_tests(list()) :: :ok
  def print_failed_tests(results) do
    failed = Enum.reject(results, & &1.passed)

    if Enum.empty?(failed) do
      :ok
    else
      IO.puts("\nFailed tests:")

      Enum.each(failed, fn r ->
        IO.puts("\n  #{r.index}. #{r.query}")
        IO.puts("     Error: #{r.error}")
        IO.puts("     Attempts: #{r.attempts}")

        if r[:all_programs] && length(r.all_programs) > 0 do
          IO.puts("     Programs tried:")

          Enum.each(r.all_programs, fn {prog, result} ->
            result_str = format_attempt_result(result)
            IO.puts("       - #{truncate(prog, 60)}")
            IO.puts("         Result: #{result_str}")
          end)
        end
      end)

      :ok
    end
  end

  # Gets the PtcRunner library version from the application spec
  defp get_ptc_runner_version do
    case Application.spec(:ptc_runner, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  # Gets the current git commit hash (short form)
  defp get_git_commit do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {hash, 0} -> String.trim(hash)
      _ -> "unknown"
    end
  end
end
