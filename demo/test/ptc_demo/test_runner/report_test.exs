defmodule PtcDemo.TestRunner.ReportTest do
  use ExUnit.Case, async: true

  alias PtcDemo.TestRunner.Report

  describe "generate/2" do
    test "generates report with correct DSL name" do
      summary =
        build_test_summary(
          passed: 2,
          failed: 1,
          total: 3,
          total_attempts: 5,
          duration_ms: 1000,
          stats: %{total_tokens: 1000, total_cost: 0.5}
        )

      report = Report.generate(summary, "JSON")

      assert String.contains?(report, "# PTC-JSON Test Report")
      assert String.contains?(report, "test-model")
      assert String.contains?(report, "schema")
    end

    test "generates report with Lisp DSL name" do
      summary =
        build_test_summary(
          data_mode: :full,
          passed: 1,
          duration_ms: 500,
          stats: %{total_tokens: 100, total_cost: 0.1}
        )

      report = Report.generate(summary, "Lisp")

      assert String.contains?(report, "# PTC-Lisp Test Report")
    end

    test "includes summary metrics in report" do
      summary =
        build_test_summary(
          model: "my-model",
          passed: 18,
          failed: 2,
          total: 20,
          total_attempts: 45,
          duration_ms: 5000,
          stats: %{total_tokens: 10000, total_cost: 0.25}
        )

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

      summary =
        build_test_summary(
          passed: 1,
          results: [result]
        )

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

      summary =
        build_test_summary(
          failed: 1,
          total_attempts: 2,
          duration_ms: 200,
          stats: %{total_tokens: 200, total_cost: 0.2},
          results: [result]
        )

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

      summary =
        build_test_summary(
          passed: 1,
          results: [result]
        )

      report = Report.generate(summary, "JSON")

      assert String.contains?(report, "## All Programs Generated")
      assert String.contains?(report, "program1")
    end

    test "handles empty results list" do
      summary = build_test_summary()

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

      summary =
        build_test_summary(
          passed: 2,
          total: 2,
          total_attempts: 5,
          results: results
        )

      report = Report.generate(summary, "JSON")

      # 5 attempts / 2 tests = 2.5
      assert String.contains?(report, "2.5")
    end

    test "formats timestamp in report" do
      timestamp = ~U[2025-01-15 14:30:45Z]

      summary = build_test_summary(timestamp: timestamp)

      report = Report.generate(summary, "JSON")

      # Should contain formatted timestamp (format: YYYY-MM-DD HH:MM:SS UTC)
      assert String.contains?(report, "2025-01-15")
    end
  end

  describe "generate_json/2" do
    test "returns map with correct structure" do
      summary =
        build_test_summary(
          passed: 18,
          failed: 2,
          total: 20,
          total_attempts: 25,
          duration_ms: 45000,
          stats: %{
            input_tokens: 50000,
            output_tokens: 5000,
            total_tokens: 55000,
            system_prompt_tokens: 2000,
            total_runs: 1,
            total_cost: 0.0275,
            requests: 20
          }
        )

      json = Report.generate_json(summary, "Lisp")

      assert json.dsl == "Lisp"
      assert json.model == "test-model"
      assert json.data_mode == "schema"
      assert json.metrics.passed == 18
      assert json.metrics.failed == 2
      assert json.metrics.total == 20
      assert json.metrics.pass_rate == 90.0
      assert json.metrics.total_attempts == 25
      assert json.metrics.avg_attempts_per_test == 1.25
      assert json.metrics.duration_ms == 45000
      assert json.stats.input_tokens == 50000
      assert json.stats.total_cost == 0.0275
    end

    test "includes trace data for failures" do
      trace = [
        %{
          number: 1,
          program: "(count users)",
          result: "{:ok, 250}",
          success: true,
          tool_calls: [],
          prints: [],
          memory_keys: []
        },
        %{
          number: 2,
          program: "(filter users)",
          result: "{:error, \"timeout\"}",
          success: false,
          tool_calls: [],
          prints: [],
          memory_keys: ["result"]
        }
      ]

      result = %{
        index: 5,
        query: "How many remote employees?",
        passed: false,
        error: "Expected 1-199, got 250",
        description: "Test",
        constraint: {:between, 1, 199},
        trace: trace
      }

      summary = build_test_summary(failed: 1, results: [result])

      json = Report.generate_json(summary, "Lisp")

      assert length(json.failures) == 1
      failure = hd(json.failures)
      assert failure.index == 5
      assert failure.query == "How many remote employees?"
      assert failure.error == "Expected 1-199, got 250"
      assert failure.trace == trace
    end

    test "handles empty results" do
      summary = build_test_summary()

      json = Report.generate_json(summary, "JSON")

      assert json.metrics.passed == 0
      assert json.metrics.failed == 0
      assert json.failures == []
    end

    test "calculates pass rate correctly for edge cases" do
      # Zero total tests
      summary = build_test_summary(total: 0, passed: 0)
      json = Report.generate_json(summary, "Test")
      assert json.metrics.pass_rate == 0.0

      # All passed
      summary = build_test_summary(total: 10, passed: 10, failed: 0)
      json = Report.generate_json(summary, "Test")
      assert json.metrics.pass_rate == 100.0
    end
  end

  describe "write/3" do
    test "writes both markdown and json files" do
      summary =
        build_test_summary(
          passed: 1,
          results: [
            %{
              index: 1,
              query: "Test",
              passed: true,
              attempts: 1,
              description: "Test"
            }
          ]
        )

      temp_md = Path.join(System.tmp_dir!(), "test_report_#{:erlang.phash2(self())}.md")
      temp_json = String.replace_suffix(temp_md, ".md", ".json")

      try do
        result = Report.write(temp_md, summary, "Test")
        assert result == temp_md

        # Verify markdown file
        assert File.exists?(temp_md)
        md_content = File.read!(temp_md)
        assert String.contains?(md_content, "# PTC-Test Test Report")
        assert String.contains?(md_content, "test-model")

        # Verify JSON file
        assert File.exists?(temp_json)
        json_content = File.read!(temp_json)
        {:ok, json} = Jason.decode(json_content)
        assert json["dsl"] == "Test"
        assert json["model"] == "test-model"
      after
        File.rm(temp_md)
        File.rm(temp_json)
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
        summary =
          build_test_summary(
            model: "new-model",
            passed: 1
          )

        result = Report.write(temp_file, summary, "Test")
        assert result == temp_file

        # Verify old content is replaced
        content = File.read!(temp_file)
        assert String.contains?(content, "new-model")
        assert !String.contains?(content, "old content")
      after
        File.rm(temp_file)
        json_file = String.replace_suffix(temp_file, ".md", ".json")
        File.rm(json_file)
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

      summary =
        build_test_summary(
          failed: 1,
          total_attempts: 5,
          duration_ms: 1000,
          stats: %{total_tokens: 500, total_cost: 0.5},
          results: [result]
        )

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

      summary =
        build_test_summary(
          passed: 1,
          results: [result]
        )

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

      summary =
        build_test_summary(
          passed: 1,
          results: [result]
        )

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

      summary =
        build_test_summary(
          failed: 1,
          results: [result]
        )

      report = Report.generate(summary, "JSON")

      assert String.contains?(report, "## Failed Tests")
      assert String.contains?(report, "Test")
    end

    test "handles very high token count and cost" do
      summary = build_test_summary(stats: %{total_tokens: 1_000_000, total_cost: 123.4567})

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

      summary =
        build_test_summary(
          passed: 1,
          results: [result]
        )

      report = Report.generate(summary, "JSON")

      assert String.contains?(report, "(some lisp code)")
    end
  end

  defp build_test_summary(overrides \\ []) do
    default_stats = %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      system_prompt_tokens: 0,
      total_runs: 0,
      total_cost: 0.0,
      requests: 0
    }

    defaults = %{
      timestamp: DateTime.utc_now(),
      model: "test-model",
      data_mode: :schema,
      passed: 0,
      failed: 0,
      total: 0,
      total_attempts: 0,
      duration_ms: 0,
      stats: default_stats,
      results: []
    }

    overrides_map = Map.new(overrides)

    # Merge stats separately to preserve all fields
    merged_stats =
      if Map.has_key?(overrides_map, :stats) do
        Map.merge(default_stats, overrides_map.stats)
      else
        default_stats
      end

    defaults
    |> Map.merge(overrides_map)
    |> Map.put(:stats, merged_stats)
  end
end
