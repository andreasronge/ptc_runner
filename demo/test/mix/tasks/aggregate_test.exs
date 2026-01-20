defmodule Mix.Tasks.AggregateTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Aggregate

  @sample_report %{
    dsl: "Lisp",
    generated: "2025-01-19 14:30:45 UTC",
    model: "openrouter:anthropic/claude-3-5-haiku-latest",
    data_mode: "schema",
    version: "0.5.1",
    commit: "ad44ee3",
    metrics: %{
      passed: 18,
      failed: 2,
      total: 20,
      pass_rate: 90.0,
      total_attempts: 25,
      avg_attempts_per_test: 1.25,
      duration_ms: 45000
    },
    stats: %{
      input_tokens: 50000,
      output_tokens: 5000,
      total_tokens: 55000,
      system_prompt_tokens: 2000,
      total_runs: 1,
      total_cost: 0.0275,
      requests: 20
    },
    failures: [
      %{
        index: 5,
        query: "How many remote employees?",
        error: "Expected 1-199, got 250",
        run: nil,
        trace: [
          %{
            number: 1,
            program: "(count (filter ...))",
            result: "{:ok, 250}",
            success: true,
            tool_calls: [],
            prints: [],
            memory_keys: []
          }
        ]
      }
    ]
  }

  describe "aggregate_reports/1" do
    test "returns error when no JSON files found" do
      temp_dir = Path.join(System.tmp_dir!(), "empty_reports_#{:erlang.phash2(self())}")
      File.mkdir_p!(temp_dir)

      try do
        assert {:error, message} = Aggregate.aggregate_reports(temp_dir)
        assert String.contains?(message, "No JSON reports found")
      after
        File.rm_rf!(temp_dir)
      end
    end

    test "returns error for single JSON report" do
      temp_dir = Path.join(System.tmp_dir!(), "single_report_#{:erlang.phash2(self())}")
      File.mkdir_p!(temp_dir)

      try do
        # Write a sample JSON report
        report_path = Path.join(temp_dir, "report1.json")
        File.write!(report_path, Jason.encode!(@sample_report))

        assert {:error, message} = Aggregate.aggregate_reports(temp_dir)
        assert String.contains?(message, "at least 2 reports")
      after
        File.rm_rf!(temp_dir)
      end
    end

    test "aggregates multiple JSON reports" do
      temp_dir = Path.join(System.tmp_dir!(), "multi_report_#{:erlang.phash2(self())}")
      File.mkdir_p!(temp_dir)

      try do
        # Write first report
        report1 = @sample_report
        File.write!(Path.join(temp_dir, "report1.json"), Jason.encode!(report1))

        # Write second report with different model
        report2 =
          @sample_report
          |> Map.put(:model, "openrouter:google/gemini-2.0-flash")
          |> put_in([:metrics, :passed], 20)
          |> put_in([:metrics, :failed], 0)
          |> put_in([:metrics, :pass_rate], 100.0)
          |> Map.put(:failures, [])

        File.write!(Path.join(temp_dir, "report2.json"), Jason.encode!(report2))

        {:ok, result} = Aggregate.aggregate_reports(temp_dir)

        assert String.contains?(result, "Reports Aggregated:** 2")
        assert String.contains?(result, "claude-3-5-haiku-latest")
        assert String.contains?(result, "gemini-2.0-flash")
        assert String.contains?(result, "Models with 100% Pass Rate | 1/2")
      after
        File.rm_rf!(temp_dir)
      end
    end

    test "includes failure traces in aggregate report" do
      temp_dir = Path.join(System.tmp_dir!(), "trace_report_#{:erlang.phash2(self())}")
      File.mkdir_p!(temp_dir)

      try do
        # Need at least 2 reports to aggregate
        File.write!(Path.join(temp_dir, "report1.json"), Jason.encode!(@sample_report))

        report2 = Map.put(@sample_report, :model, "other-model")
        File.write!(Path.join(temp_dir, "report2.json"), Jason.encode!(report2))

        {:ok, result} = Aggregate.aggregate_reports(temp_dir)

        assert String.contains?(result, "## Failures")
        assert String.contains?(result, "How many remote employees?")
        assert String.contains?(result, "Expected 1-199, got 250")
        assert String.contains?(result, "Execution trace")
        assert String.contains?(result, "(count (filter ...))")
      after
        File.rm_rf!(temp_dir)
      end
    end

    test "handles reports with no failures" do
      temp_dir = Path.join(System.tmp_dir!(), "no_failures_#{:erlang.phash2(self())}")
      File.mkdir_p!(temp_dir)

      try do
        report =
          @sample_report
          |> put_in([:metrics, :passed], 20)
          |> put_in([:metrics, :failed], 0)
          |> Map.put(:failures, [])

        # Need at least 2 reports to aggregate
        File.write!(Path.join(temp_dir, "report1.json"), Jason.encode!(report))

        report2 = Map.put(report, :model, "other-model")
        File.write!(Path.join(temp_dir, "report2.json"), Jason.encode!(report2))

        {:ok, result} = Aggregate.aggregate_reports(temp_dir)

        assert String.contains?(result, "No failures across any model")
      after
        File.rm_rf!(temp_dir)
      end
    end

    test "skips invalid JSON files gracefully" do
      temp_dir = Path.join(System.tmp_dir!(), "invalid_json_#{:erlang.phash2(self())}")
      File.mkdir_p!(temp_dir)

      try do
        # Write two valid reports
        File.write!(Path.join(temp_dir, "valid1.json"), Jason.encode!(@sample_report))

        report2 = Map.put(@sample_report, :model, "other-model")
        File.write!(Path.join(temp_dir, "valid2.json"), Jason.encode!(report2))

        # Write invalid JSON
        File.write!(Path.join(temp_dir, "invalid.json"), "not valid json {{{")

        {:ok, result} = Aggregate.aggregate_reports(temp_dir)

        # Should still produce a report from the valid files
        assert String.contains?(result, "# Benchmark Aggregate Report")
        assert String.contains?(result, "Reports Aggregated:** 2")
      after
        File.rm_rf!(temp_dir)
      end
    end

    test "calculates aggregate statistics correctly" do
      temp_dir = Path.join(System.tmp_dir!(), "stats_#{:erlang.phash2(self())}")
      File.mkdir_p!(temp_dir)

      try do
        report1 =
          @sample_report
          |> put_in([:metrics, :total], 10)
          |> put_in([:metrics, :passed], 8)
          |> put_in([:metrics, :failed], 2)
          |> put_in([:stats, :total_tokens], 1000)
          |> put_in([:stats, :total_cost], 0.01)

        report2 =
          @sample_report
          |> put_in([:metrics, :total], 10)
          |> put_in([:metrics, :passed], 9)
          |> put_in([:metrics, :failed], 1)
          |> put_in([:stats, :total_tokens], 2000)
          |> put_in([:stats, :total_cost], 0.02)

        File.write!(Path.join(temp_dir, "r1.json"), Jason.encode!(report1))
        File.write!(Path.join(temp_dir, "r2.json"), Jason.encode!(report2))

        {:ok, result} = Aggregate.aggregate_reports(temp_dir)

        # Total tests: 10 + 10 = 20
        assert String.contains?(result, "Total Tests Across All Models | 20")
        # Total passed: 8 + 9 = 17
        assert String.contains?(result, "Total Passed | 17")
        # Total failed: 2 + 1 = 3
        assert String.contains?(result, "Total Failed | 3")
        # Total tokens: 1000 + 2000 = 3000
        assert String.contains?(result, "Total Tokens | 3,000")
        # Total cost: 0.01 + 0.02 = 0.03
        assert String.contains?(result, "$0.03")
      after
        File.rm_rf!(temp_dir)
      end
    end
  end
end
