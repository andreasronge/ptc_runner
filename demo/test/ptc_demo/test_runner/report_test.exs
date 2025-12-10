defmodule PtcDemo.TestRunner.ReportTest do
  use ExUnit.Case, async: true

  alias PtcDemo.TestRunner.Report

  describe "generate/2" do
    test "generates report with correct DSL name" do
      summary = %{
        timestamp: DateTime.utc_now(),
        model: "test-model",
        data_mode: :schema,
        passed: 2,
        failed: 1,
        total: 3,
        total_attempts: 5,
        duration_ms: 1000,
        stats: %{total_tokens: 1000, total_cost: 0.5},
        results: []
      }

      report = Report.generate(summary, "JSON")

      assert String.contains?(report, "# PTC-JSON Test Report")
      assert String.contains?(report, "test-model")
      assert String.contains?(report, "schema")
    end

    test "generates report with Lisp DSL name" do
      summary = %{
        timestamp: DateTime.utc_now(),
        model: "test-model",
        data_mode: :full,
        passed: 1,
        failed: 0,
        total: 1,
        total_attempts: 1,
        duration_ms: 500,
        stats: %{total_tokens: 100, total_cost: 0.1},
        results: []
      }

      report = Report.generate(summary, "Lisp")

      assert String.contains?(report, "# PTC-Lisp Test Report")
    end

    test "includes summary metrics in report" do
      summary = %{
        timestamp: DateTime.utc_now(),
        model: "my-model",
        data_mode: :schema,
        passed: 18,
        failed: 2,
        total: 20,
        total_attempts: 45,
        duration_ms: 5000,
        stats: %{total_tokens: 10000, total_cost: 0.25},
        results: []
      }

      report = Report.generate(summary, "JSON")

      assert String.contains?(report, "18/20")
      assert String.contains?(report, "2")
      assert String.contains?(report, "45")
      assert String.contains?(report, "my-model")
    end

    test "includes all passed tests (no failed section)" do
      result = %{
        index: 1,
        query: "Test query",
        passed: true,
        attempts: 1,
        description: "Test description"
      }

      summary = %{
        timestamp: DateTime.utc_now(),
        model: "model",
        data_mode: :schema,
        passed: 1,
        failed: 0,
        total: 1,
        total_attempts: 1,
        duration_ms: 100,
        stats: %{total_tokens: 100, total_cost: 0.1},
        results: [result]
      }

      report = Report.generate(summary, "JSON")

      assert String.contains?(report, "| 1 |")
      assert String.contains?(report, "PASS")
      # No failed tests section when all pass
      assert !String.contains?(report, "## Failed Tests")
    end

    test "includes failed test details section" do
      result = %{
        index: 1,
        query: "How many?",
        passed: false,
        attempts: 2,
        error: "Expected 500, got 499",
        description: "Test description",
        constraint: {:eq, 500},
        all_programs: [
          {"(count)", {:ok, 499}},
          {"(count all)", {:error, "undefined"}}
        ]
      }

      summary = %{
        timestamp: DateTime.utc_now(),
        model: "model",
        data_mode: :schema,
        passed: 0,
        failed: 1,
        total: 1,
        total_attempts: 2,
        duration_ms: 200,
        stats: %{total_tokens: 200, total_cost: 0.2},
        results: [result]
      }

      report = Report.generate(summary, "JSON")

      assert String.contains?(report, "## Failed Tests")
      assert String.contains?(report, "How many?")
      assert String.contains?(report, "Expected 500, got 499")
      assert String.contains?(report, "Programs tried")
    end

    test "includes all programs section" do
      result = %{
        index: 1,
        query: "Test",
        passed: true,
        attempts: 1,
        all_programs: [{"program1", {:ok, 42}}]
      }

      summary = %{
        timestamp: DateTime.utc_now(),
        model: "model",
        data_mode: :schema,
        passed: 1,
        failed: 0,
        total: 1,
        total_attempts: 1,
        duration_ms: 100,
        stats: %{total_tokens: 100, total_cost: 0.1},
        results: [result]
      }

      report = Report.generate(summary, "JSON")

      assert String.contains?(report, "## All Programs Generated")
      assert String.contains?(report, "program1")
    end

    test "handles empty results list" do
      summary = %{
        timestamp: DateTime.utc_now(),
        model: "model",
        data_mode: :schema,
        passed: 0,
        failed: 0,
        total: 0,
        total_attempts: 0,
        duration_ms: 0,
        stats: %{total_tokens: 0, total_cost: 0.0},
        results: []
      }

      report = Report.generate(summary, "JSON")

      assert String.contains?(report, "# PTC-JSON Test Report")
      assert String.contains?(report, "## Summary")
      assert String.contains?(report, "## Results")
    end

    test "calculates average attempts per test" do
      results = [
        %{index: 1, query: "Q1", passed: true, attempts: 2},
        %{index: 2, query: "Q2", passed: true, attempts: 3}
      ]

      summary = %{
        timestamp: DateTime.utc_now(),
        model: "model",
        data_mode: :schema,
        passed: 2,
        failed: 0,
        total: 2,
        total_attempts: 5,
        duration_ms: 100,
        stats: %{total_tokens: 100, total_cost: 0.1},
        results: results
      }

      report = Report.generate(summary, "JSON")

      # 5 attempts / 2 tests = 2.5
      assert String.contains?(report, "2.5")
    end

    test "formats timestamp in report" do
      timestamp = ~U[2025-01-15 14:30:45Z]

      summary = %{
        timestamp: timestamp,
        model: "model",
        data_mode: :schema,
        passed: 0,
        failed: 0,
        total: 0,
        total_attempts: 0,
        duration_ms: 0,
        stats: %{total_tokens: 0, total_cost: 0.0},
        results: []
      }

      report = Report.generate(summary, "JSON")

      # Should contain formatted timestamp (format: YYYY-MM-DD HH:MM:SS UTC)
      assert String.contains?(report, "2025-01-15")
    end
  end

  describe "write/3" do
    test "writes report to file" do
      summary = %{
        timestamp: DateTime.utc_now(),
        model: "test-model",
        data_mode: :schema,
        passed: 1,
        failed: 0,
        total: 1,
        total_attempts: 1,
        duration_ms: 100,
        stats: %{total_tokens: 100, total_cost: 0.1},
        results: [
          %{
            index: 1,
            query: "Test",
            passed: true,
            attempts: 1,
            description: "Test"
          }
        ]
      }

      temp_file = Path.join(System.tmp_dir!(), "test_report_#{:erlang.phash2(self())}.md")

      try do
        :ok = Report.write(temp_file, summary, "Test")

        assert File.exists?(temp_file)

        content = File.read!(temp_file)
        assert String.contains?(content, "# PTC-Test Test Report")
        assert String.contains?(content, "test-model")
      after
        File.rm(temp_file)
      end
    end

    test "overwrites existing file" do
      temp_file =
        Path.join(System.tmp_dir!(), "test_report_overwrite_#{:erlang.phash2(self())}.md")

      try do
        # Write initial file
        File.write!(temp_file, "old content")
        assert File.read!(temp_file) == "old content"

        # Generate new report
        summary = %{
          timestamp: DateTime.utc_now(),
          model: "new-model",
          data_mode: :schema,
          passed: 1,
          failed: 0,
          total: 1,
          total_attempts: 1,
          duration_ms: 100,
          stats: %{total_tokens: 100, total_cost: 0.1},
          results: []
        }

        :ok = Report.write(temp_file, summary, "Test")

        # Verify old content is replaced
        content = File.read!(temp_file)
        assert String.contains?(content, "new-model")
        assert !String.contains?(content, "old content")
      after
        File.rm(temp_file)
      end
    end
  end

  describe "report format edge cases" do
    test "handles multi-turn queries with many programs" do
      result = %{
        index: 1,
        query: "Multi-turn test",
        passed: false,
        attempts: 5,
        error: "Did not converge",
        description: "Test",
        constraint: {:eq, 100},
        all_programs: [
          {"program1", {:ok, 50}},
          {"program2", {:ok, 75}},
          {"program3", {:error, "invalid"}},
          {"program4", {:ok, 90}},
          {"program5", {:error, "timeout"}}
        ]
      }

      summary = %{
        timestamp: DateTime.utc_now(),
        model: "model",
        data_mode: :schema,
        passed: 0,
        failed: 1,
        total: 1,
        total_attempts: 5,
        duration_ms: 1000,
        stats: %{total_tokens: 500, total_cost: 0.5},
        results: [result]
      }

      report = Report.generate(summary, "JSON")

      assert String.contains?(report, "5")
      assert String.contains?(report, "program1")
      assert String.contains?(report, "program5")
    end

    test "handles long query strings in table" do
      result = %{
        index: 1,
        query:
          "This is a very long query string that should be truncated in the table view for readability",
        passed: true,
        attempts: 1
      }

      summary = %{
        timestamp: DateTime.utc_now(),
        model: "model",
        data_mode: :schema,
        passed: 1,
        failed: 0,
        total: 1,
        total_attempts: 1,
        duration_ms: 100,
        stats: %{total_tokens: 100, total_cost: 0.1},
        results: [result]
      }

      report = Report.generate(summary, "JSON")

      # Should contain truncated query
      assert String.contains?(report, "This is a very long query")
    end

    test "handles results without all_programs field" do
      result = %{
        index: 1,
        query: "Test",
        passed: true,
        attempts: 1
      }

      summary = %{
        timestamp: DateTime.utc_now(),
        model: "model",
        data_mode: :schema,
        passed: 1,
        failed: 0,
        total: 1,
        total_attempts: 1,
        duration_ms: 100,
        stats: %{total_tokens: 100, total_cost: 0.1},
        results: [result]
      }

      report = Report.generate(summary, "JSON")

      # Should handle gracefully (no crash)
      assert String.contains?(report, "# PTC-JSON Test Report")
    end

    test "handles results with empty all_programs list" do
      result = %{
        index: 1,
        query: "Test",
        passed: false,
        attempts: 1,
        error: "Error",
        description: "Test",
        constraint: nil,
        all_programs: []
      }

      summary = %{
        timestamp: DateTime.utc_now(),
        model: "model",
        data_mode: :schema,
        passed: 0,
        failed: 1,
        total: 1,
        total_attempts: 1,
        duration_ms: 100,
        stats: %{total_tokens: 100, total_cost: 0.1},
        results: [result]
      }

      report = Report.generate(summary, "JSON")

      assert String.contains?(report, "## Failed Tests")
      assert String.contains?(report, "Test")
    end

    test "handles very high token count and cost" do
      summary = %{
        timestamp: DateTime.utc_now(),
        model: "model",
        data_mode: :schema,
        passed: 0,
        failed: 0,
        total: 0,
        total_attempts: 0,
        duration_ms: 0,
        stats: %{total_tokens: 1_000_000, total_cost: 123.4567},
        results: []
      }

      report = Report.generate(summary, "JSON")

      assert String.contains?(report, "1000000")
      assert String.contains?(report, "$123.4567")
    end

    test "handles result with program field" do
      result = %{
        index: 1,
        query: "Test",
        passed: true,
        attempts: 1,
        program: "(some lisp code)"
      }

      summary = %{
        timestamp: DateTime.utc_now(),
        model: "model",
        data_mode: :schema,
        passed: 1,
        failed: 0,
        total: 1,
        total_attempts: 1,
        duration_ms: 100,
        stats: %{total_tokens: 100, total_cost: 0.1},
        results: [result]
      }

      report = Report.generate(summary, "JSON")

      assert String.contains?(report, "(some lisp code)")
    end
  end
end
