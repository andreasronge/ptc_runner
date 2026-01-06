defmodule PtcDemo.TestRunner.BaseTest do
  use ExUnit.Case, async: true

  alias PtcDemo.TestRunner.Base

  describe "check_type/2" do
    test "integer type accepts only integers" do
      assert Base.check_type(42, :integer) == true
      assert Base.check_type(42.0, :integer) == false
      assert Base.check_type("42", :integer) == false
    end

    test "number type accepts integers and floats" do
      assert Base.check_type(42, :number) == true
      assert Base.check_type(42.5, :number) == true
      assert Base.check_type("42", :number) == false
    end

    test "string type accepts binary strings" do
      assert Base.check_type("hello", :string) == true
      assert Base.check_type(<<104, 105>>, :string) == true
      assert Base.check_type(42, :string) == false
    end

    test "list type accepts lists" do
      assert Base.check_type([1, 2, 3], :list) == true
      assert Base.check_type([], :list) == true
      assert Base.check_type("not a list", :list) == false
    end

    test "map type accepts maps" do
      assert Base.check_type(%{}, :map) == true
      assert Base.check_type(%{"key" => "value"}, :map) == true
      assert Base.check_type([1, 2], :map) == false
    end

    test "unknown types return true" do
      assert Base.check_type(42, :anything) == true
      assert Base.check_type("string", :unknown) == true
      assert Base.check_type(nil, :custom) == true
    end
  end

  describe "check_constraint/2" do
    test "eq constraint passes on exact match" do
      assert Base.check_constraint(500, {:eq, 500}) == true
      assert Base.check_constraint("test", {:eq, "test"}) == true
    end

    test "eq constraint returns error message on mismatch" do
      assert Base.check_constraint(499, {:eq, 500}) == "Expected 500, got 499"
      assert Base.check_constraint("hello", {:eq, "world"}) == ~s(Expected "world", got "hello")
    end

    test "gt constraint passes when value is greater" do
      assert Base.check_constraint(100, {:gt, 50}) == true
      assert Base.check_constraint(51, {:gt, 50}) == true
    end

    test "gt constraint fails when value is not greater" do
      assert Base.check_constraint(50, {:gt, 50}) == "Expected > 50, got 50"
      assert Base.check_constraint(49, {:gt, 50}) == "Expected > 50, got 49"
    end

    test "gte constraint passes when value is greater or equal" do
      assert Base.check_constraint(100, {:gte, 50}) == true
      assert Base.check_constraint(50, {:gte, 50}) == true
    end

    test "gte constraint fails when value is less" do
      assert Base.check_constraint(49, {:gte, 50}) == "Expected >= 50, got 49"
    end

    test "lt constraint passes when value is less" do
      assert Base.check_constraint(49, {:lt, 50}) == true
      assert Base.check_constraint(0, {:lt, 50}) == true
    end

    test "lt constraint fails when value is not less" do
      assert Base.check_constraint(50, {:lt, 50}) == "Expected < 50, got 50"
      assert Base.check_constraint(51, {:lt, 50}) == "Expected < 50, got 51"
    end

    test "between constraint passes when in range (inclusive)" do
      assert Base.check_constraint(50, {:between, 1, 100}) == true
      assert Base.check_constraint(1, {:between, 1, 100}) == true
      assert Base.check_constraint(100, {:between, 1, 100}) == true
    end

    test "between constraint fails when out of range" do
      assert Base.check_constraint(0, {:between, 1, 100}) == "Expected between 1-100, got 0"
      assert Base.check_constraint(101, {:between, 1, 100}) == "Expected between 1-100, got 101"
    end

    test "length constraint passes for matching list length" do
      assert Base.check_constraint([1, 2, 3], {:length, 3}) == true
      assert Base.check_constraint([], {:length, 0}) == true
    end

    test "length constraint fails for non-matching list length" do
      assert Base.check_constraint([1, 2], {:length, 3}) == "Expected length 3, got 2"
      assert Base.check_constraint([1, 2, 3], {:length, 0}) == "Expected length 0, got 3"
    end

    test "length constraint only applies to lists" do
      # Non-list values should return true (no validation)
      assert Base.check_constraint("string", {:length, 5}) == true
      assert Base.check_constraint(123, {:length, 3}) == true
    end

    test "starts_with constraint passes for matching prefix" do
      assert Base.check_constraint("hello world", {:starts_with, "hello"}) == true
      assert Base.check_constraint("Product123", {:starts_with, "Product"}) == true
    end

    test "starts_with constraint fails for non-matching prefix" do
      result = Base.check_constraint("world hello", {:starts_with, "hello"})
      assert String.contains?(result, "Expected to start with 'hello'")
    end

    test "starts_with constraint only applies to strings" do
      # Non-string values should return true (no validation)
      assert Base.check_constraint([1, 2, 3], {:starts_with, "test"}) == true
      assert Base.check_constraint(123, {:starts_with, "1"}) == true
    end

    test "unknown constraints return true" do
      assert Base.check_constraint(42, {:unknown, "constraint"}) == true
      assert Base.check_constraint(nil, {:custom}) == true
      assert Base.check_constraint("anything", :no_constraint) == true
    end

    test "nil constraint returns true" do
      assert Base.check_constraint(42, nil) == true
      assert Base.check_constraint("string", nil) == true
    end
  end

  describe "format_cost/1" do
    test "formats positive floats with $ prefix and 4 decimals" do
      assert Base.format_cost(1.5) == "$1.5000"
      assert Base.format_cost(0.123) == "$0.1230"
      assert Base.format_cost(1000.0) == "$1000.0000"
    end

    test "returns $0.00 for zero or negative" do
      assert Base.format_cost(0.0) == "$0.00"
      assert Base.format_cost(-1.5) == "$0.00"
    end

    test "returns $0.00 for non-floats" do
      assert Base.format_cost(nil) == "$0.00"
      assert Base.format_cost("not a number") == "$0.00"
      assert Base.format_cost(42) == "$0.00"
    end

    test "returns $0.00 for empty list or map" do
      assert Base.format_cost([]) == "$0.00"
      assert Base.format_cost(%{}) == "$0.00"
    end
  end

  describe "format_duration/1" do
    test "formats milliseconds under 1 second as ms" do
      assert Base.format_duration(0) == "0ms"
      assert Base.format_duration(500) == "500ms"
      assert Base.format_duration(999) == "999ms"
    end

    test "formats seconds under 1 minute as s" do
      assert Base.format_duration(1000) == "1.0s"
      assert Base.format_duration(1500) == "1.5s"
      assert Base.format_duration(59_999) == "60.0s"
    end

    test "formats minutes and above as m" do
      assert Base.format_duration(60_000) == "1.0m"
      assert Base.format_duration(90_000) == "1.5m"
      assert Base.format_duration(120_000) == "2.0m"
    end
  end

  describe "format_attempt_result/1" do
    test "formats error tuples with ERROR prefix" do
      assert Base.format_attempt_result({:error, "Something went wrong"}) ==
               "ERROR: Something went wrong"
    end

    test "truncates error messages over 50 characters" do
      long_error = String.duplicate("a", 60)
      result = Base.format_attempt_result({:error, long_error})
      assert String.length(result) <= String.length("ERROR: ...") + 50
    end

    test "formats other values as inspected strings" do
      assert Base.format_attempt_result(42) == "42"
      assert Base.format_attempt_result([1, 2, 3]) == "[1, 2, 3]"
    end

    test "truncates long inspect results" do
      long_list = Enum.to_list(1..100)
      result = Base.format_attempt_result(long_list)
      assert String.ends_with?(result, "...")
      assert String.length(result) <= 53
    end
  end

  describe "truncate/2" do
    test "returns string unchanged if within limit" do
      assert Base.truncate("hello", 10) == "hello"
      assert Base.truncate("hello", 5) == "hello"
    end

    test "truncates and adds ... if over limit" do
      assert Base.truncate("hello world", 8) == "hello wo..."
      assert Base.truncate("hello world", 5) == "hello..."
    end

    test "normalizes whitespace" do
      assert Base.truncate("hello  world", 20) == "hello world"
      assert Base.truncate("  hello   world  ", 20) == "hello world"
      assert Base.truncate("tab\there", 20) == "tab here"
    end

    test "normalizes whitespace before truncating" do
      assert Base.truncate("hello   world   test", 12) == "hello world ..."
    end

    test "handles non-string inputs by inspecting first" do
      assert Base.truncate(42, 10) == "42"
      assert Base.truncate([1, 2, 3], 5) == "[1, 2..."
    end

    test "handles empty strings" do
      assert Base.truncate("", 10) == ""
    end
  end

  describe "type_of/1" do
    test "returns :integer for integers" do
      assert Base.type_of(0) == :integer
      assert Base.type_of(42) == :integer
      assert Base.type_of(-1) == :integer
    end

    test "returns :float for floats" do
      assert Base.type_of(1.0) == :float
      assert Base.type_of(42.5) == :float
      assert Base.type_of(-1.5) == :float
    end

    test "returns :string for binary strings" do
      assert Base.type_of("hello") == :string
      assert Base.type_of("") == :string
      assert Base.type_of(<<104, 105>>) == :string
    end

    test "returns :list for lists" do
      assert Base.type_of([]) == :list
      assert Base.type_of([1, 2, 3]) == :list
      assert Base.type_of(["a", "b"]) == :list
    end

    test "returns :map for maps" do
      assert Base.type_of(%{}) == :map
      assert Base.type_of(%{"key" => "value"}) == :map
      assert Base.type_of(%{a: 1}) == :map
    end

    test "returns :boolean for booleans" do
      assert Base.type_of(true) == :boolean
      assert Base.type_of(false) == :boolean
    end

    test "returns nil for nil" do
      assert Base.type_of(nil) == nil
    end

    test "returns :unknown for other types" do
      assert Base.type_of(:atom) == :unknown
      assert Base.type_of({1, 2}) == :unknown
      assert Base.type_of(fn -> nil end) == :unknown
    end
  end

  describe "validate_result/2" do
    test "passes when type and constraint match" do
      test_case = %{expect: :integer, constraint: {:eq, 500}}
      result = Base.validate_result(500, test_case)
      assert result.passed == true
      assert result.value == 500
      assert !Map.has_key?(result, :error)
    end

    test "fails when type is wrong" do
      test_case = %{expect: :integer, constraint: {:eq, 500}}
      result = Base.validate_result("500", test_case)
      assert result.passed == false
      assert String.contains?(result.error, "Wrong type")
      assert String.contains?(result.error, "expected integer")
    end

    test "fails when constraint is not met" do
      test_case = %{expect: :integer, constraint: {:eq, 500}}
      result = Base.validate_result(499, test_case)
      assert result.passed == false
      assert String.contains?(result.error, "Expected 500, got 499")
    end

    test "type validation takes precedence over constraint validation" do
      test_case = %{expect: :integer, constraint: {:eq, 500}}
      result = Base.validate_result("anything", test_case)
      assert result.passed == false
      assert String.contains?(result.error, "Wrong type")
    end

    test "handles constraints that return error messages" do
      test_case = %{expect: :number, constraint: {:between, 1, 100}}
      result = Base.validate_result(101, test_case)
      assert result.passed == false
      assert String.contains?(result.error, "Expected between 1-100")
    end

    test "handles nil constraints" do
      test_case = %{expect: :string, constraint: nil}
      result = Base.validate_result("hello", test_case)
      assert result.passed == true
      assert result.value == "hello"
    end
  end

  describe "build_summary/5" do
    test "aggregates results correctly" do
      results = [
        %{passed: true, attempts: 1},
        %{passed: true, attempts: 1},
        %{passed: false, attempts: 3}
      ]

      start_time = System.monotonic_time(:millisecond)

      summary =
        Base.build_summary(results, start_time, "test-model", :schema, %{
          total_tokens: 1000,
          total_cost: 0.5
        })

      assert summary.passed == 2
      assert summary.failed == 1
      assert summary.total == 3
      assert summary.total_attempts == 5
      assert summary.model == "test-model"
      assert summary.data_mode == :schema
      assert summary.stats == %{total_tokens: 1000, total_cost: 0.5}
      assert is_map(summary.timestamp)
      assert summary.duration_ms >= 0
    end

    test "handles empty results" do
      start_time = System.monotonic_time(:millisecond)

      summary =
        Base.build_summary([], start_time, "model", :schema, %{total_tokens: 0, total_cost: 0.0})

      assert summary.passed == 0
      assert summary.failed == 0
      assert summary.total == 0
      assert summary.total_attempts == 0
    end

    test "includes timestamp" do
      results = [%{passed: true, attempts: 1}]
      start_time = System.monotonic_time(:millisecond)

      summary =
        Base.build_summary(results, start_time, "model", :schema, %{
          total_tokens: 0,
          total_cost: 0.0
        })

      assert summary.timestamp |> DateTime.to_date()
      assert summary.results == results
    end
  end

  describe "print_summary/1" do
    test "prints summary information" do
      summary = %{
        passed: 18,
        failed: 2,
        total: 20,
        total_attempts: 45,
        duration_ms: 5000,
        model: "test-model",
        stats: %{total_tokens: 10000, total_cost: 0.25}
      }

      # Capture output
      captured = ExUnit.CaptureIO.capture_io(fn -> Base.print_summary(summary) end)

      assert String.contains?(captured, "18/20 passed")
      assert String.contains?(captured, "2 failed")
      assert String.contains?(captured, "test-model")
      assert String.contains?(captured, "Total attempts: 45")
    end
  end

  describe "print_failed_tests/1" do
    test "prints nothing when all tests passed" do
      results = [
        %{passed: true, index: 1, query: "test"}
      ]

      captured = ExUnit.CaptureIO.capture_io(fn -> Base.print_failed_tests(results) end)
      assert captured == ""
    end

    test "prints failed tests with details" do
      results = [
        %{
          passed: false,
          index: 1,
          query: "How many?",
          error: "Expected 500, got 499",
          attempts: 2,
          all_programs: []
        }
      ]

      captured = ExUnit.CaptureIO.capture_io(fn -> Base.print_failed_tests(results) end)

      assert String.contains?(captured, "Failed tests")
      assert String.contains?(captured, "How many?")
      assert String.contains?(captured, "Expected 500, got 499")
      assert String.contains?(captured, "Attempts: 2")
    end

    test "prints programs tried for failed tests" do
      results = [
        %{
          passed: false,
          index: 1,
          query: "test",
          error: "error",
          attempts: 2,
          all_programs: [
            {"(test)", {:ok, 42}},
            {"(test 2)", {:error, "fail"}}
          ]
        }
      ]

      captured = ExUnit.CaptureIO.capture_io(fn -> Base.print_failed_tests(results) end)

      assert String.contains?(captured, "Programs tried")
      assert String.contains?(captured, "(test)")
      assert String.contains?(captured, "ERROR: fail")
    end
  end

  describe "build_aggregate_summary/1" do
    test "single summary returns as-is" do
      summary = %{
        passed: 5,
        failed: 2,
        total: 7,
        total_attempts: 10,
        duration_ms: 1000,
        model: "test-model",
        data_mode: :schema,
        results: [%{passed: true}],
        stats: %{
          input_tokens: 100,
          output_tokens: 50,
          total_tokens: 150,
          system_prompt_tokens: 20,
          total_runs: 1,
          total_cost: 0.01
        },
        timestamp: DateTime.utc_now(),
        version: "1.0",
        commit: "abc123"
      }

      assert Base.build_aggregate_summary([summary]) == summary
    end

    test "multiple summaries are aggregated correctly" do
      summary1 = %{
        passed: 15,
        failed: 2,
        total: 17,
        total_attempts: 20,
        duration_ms: 1000,
        model: "test-model",
        data_mode: :schema,
        results: [
          %{passed: true, index: 1},
          %{passed: false, index: 2, error: "fail1"}
        ],
        stats: %{
          input_tokens: 100,
          output_tokens: 50,
          total_tokens: 150,
          system_prompt_tokens: 20,
          total_runs: 1,
          total_cost: 0.01,
          requests: 5
        },
        timestamp: DateTime.utc_now(),
        version: "1.0",
        commit: "abc123"
      }

      summary2 = %{
        passed: 16,
        failed: 1,
        total: 17,
        total_attempts: 18,
        duration_ms: 900,
        model: "test-model",
        data_mode: :schema,
        results: [
          %{passed: true, index: 1},
          %{passed: false, index: 3, error: "fail2"}
        ],
        stats: %{
          input_tokens: 80,
          output_tokens: 40,
          total_tokens: 120,
          system_prompt_tokens: 20,
          total_runs: 1,
          total_cost: 0.008,
          requests: 4
        },
        timestamp: DateTime.utc_now(),
        version: "1.0",
        commit: "abc123"
      }

      aggregate = Base.build_aggregate_summary([summary1, summary2])

      assert aggregate.passed == 31
      assert aggregate.failed == 3
      assert aggregate.total == 34
      assert aggregate.total_attempts == 38
      assert aggregate.duration_ms == 1900
      assert aggregate.model == "test-model"
      assert aggregate.num_runs == 2
      assert aggregate.stats.total_runs == 2
      assert aggregate.stats.input_tokens == 180
      assert aggregate.stats.output_tokens == 90
      assert aggregate.stats.total_tokens == 270
      assert aggregate.stats.requests == 9
      assert_in_delta aggregate.stats.total_cost, 0.018, 0.001
    end

    test "failed tests are tagged with run number" do
      summary1 = %{
        passed: 1,
        failed: 1,
        total: 2,
        total_attempts: 2,
        duration_ms: 500,
        model: "test-model",
        data_mode: :schema,
        results: [
          %{passed: true, index: 1},
          %{passed: false, index: 2, error: "fail"}
        ],
        stats: %{
          input_tokens: 50,
          output_tokens: 25,
          total_tokens: 75,
          system_prompt_tokens: 10,
          total_runs: 1,
          total_cost: 0.005
        },
        version: "1.0",
        commit: "abc123"
      }

      summary2 = %{
        passed: 2,
        failed: 0,
        total: 2,
        total_attempts: 2,
        duration_ms: 400,
        model: "test-model",
        data_mode: :schema,
        results: [
          %{passed: true, index: 1},
          %{passed: true, index: 2}
        ],
        stats: %{
          input_tokens: 50,
          output_tokens: 25,
          total_tokens: 75,
          system_prompt_tokens: 10,
          total_runs: 1,
          total_cost: 0.005
        },
        version: "1.0",
        commit: "abc123"
      }

      aggregate = Base.build_aggregate_summary([summary1, summary2])

      # Find the failed result and check it's tagged with run 1
      failed_result = Enum.find(aggregate.results, &(!&1.passed))
      assert failed_result.failed_in_run == 1
    end
  end
end
