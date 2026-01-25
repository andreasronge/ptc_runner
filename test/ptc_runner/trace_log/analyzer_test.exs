defmodule PtcRunner.TraceLog.AnalyzerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TraceLog.Analyzer

  @moduletag :tmp_dir

  defp sample_events do
    [
      %{
        "event" => "trace.start",
        "trace_id" => "test-trace",
        "timestamp" => "2024-01-15T10:00:00.000Z",
        "meta" => %{}
      },
      %{
        "event" => "run.start",
        "trace_id" => "test-trace",
        "timestamp" => "2024-01-15T10:00:00.010Z",
        "span_id" => "run-1",
        "metadata" => %{"agent" => %{"name" => "test"}}
      },
      %{
        "event" => "turn.start",
        "trace_id" => "test-trace",
        "timestamp" => "2024-01-15T10:00:00.020Z",
        "span_id" => "turn-1",
        "parent_span_id" => "run-1",
        "metadata" => %{"turn" => 1}
      },
      %{
        "event" => "llm.start",
        "trace_id" => "test-trace",
        "timestamp" => "2024-01-15T10:00:00.030Z",
        "span_id" => "llm-1",
        "parent_span_id" => "turn-1",
        "metadata" => %{}
      },
      %{
        "event" => "llm.stop",
        "trace_id" => "test-trace",
        "timestamp" => "2024-01-15T10:00:00.150Z",
        "span_id" => "llm-1",
        "parent_span_id" => "turn-1",
        "duration_ms" => 120,
        "metadata" => %{}
      },
      %{
        "event" => "tool.start",
        "trace_id" => "test-trace",
        "timestamp" => "2024-01-15T10:00:00.160Z",
        "span_id" => "tool-1",
        "parent_span_id" => "turn-1",
        "metadata" => %{"tool_name" => "get_weather"}
      },
      %{
        "event" => "tool.stop",
        "trace_id" => "test-trace",
        "timestamp" => "2024-01-15T10:00:00.200Z",
        "span_id" => "tool-1",
        "parent_span_id" => "turn-1",
        "duration_ms" => 40,
        "metadata" => %{"tool_name" => "get_weather"}
      },
      %{
        "event" => "turn.stop",
        "trace_id" => "test-trace",
        "timestamp" => "2024-01-15T10:00:00.210Z",
        "span_id" => "turn-1",
        "parent_span_id" => "run-1",
        "duration_ms" => 190,
        "metadata" => %{"turn" => 1}
      },
      %{
        "event" => "run.stop",
        "trace_id" => "test-trace",
        "timestamp" => "2024-01-15T10:00:00.220Z",
        "span_id" => "run-1",
        "duration_ms" => 210,
        "metadata" => %{
          "status" => "ok",
          "step" => %{
            "usage" => %{
              "turns" => 1,
              "input_tokens" => 100,
              "output_tokens" => 50,
              "total_tokens" => 150
            }
          }
        }
      }
    ]
  end

  describe "load/1" do
    test "loads events from JSONL file", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      events = sample_events()

      content = Enum.map_join(events, "\n", &Jason.encode!/1)
      File.write!(path, content)

      loaded = Analyzer.load(path)

      assert length(loaded) == 9
      assert Enum.at(loaded, 0)["event"] == "trace.start"
      assert Enum.at(loaded, 1)["event"] == "run.start"
    end

    test "handles empty lines", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      content = ~s({"event":"test1"}\n\n{"event":"test2"}\n)
      File.write!(path, content)

      loaded = Analyzer.load(path)

      assert length(loaded) == 2
    end
  end

  describe "summary/1" do
    test "extracts key metrics from events" do
      events = sample_events()
      summary = Analyzer.summary(events)

      assert summary.duration_ms == 210
      assert summary.turns == 1
      assert summary.llm_calls == 1
      assert summary.tool_calls == 1
      assert summary.status == "ok"
      assert summary.tokens.input == 100
      assert summary.tokens.output == 50
      assert summary.tokens.total == 150
    end

    test "handles missing run.stop event" do
      events = [
        %{"event" => "run.start", "metadata" => %{}},
        %{"event" => "llm.stop", "metadata" => %{}}
      ]

      summary = Analyzer.summary(events)

      assert summary.duration_ms == nil
      assert summary.turns == nil
      assert summary.llm_calls == 1
      assert summary.tool_calls == 0
    end
  end

  describe "filter/2" do
    test "filters by event type" do
      events = sample_events()

      llm_events = Analyzer.filter(events, type: "llm")

      assert length(llm_events) == 2
      assert Enum.all?(llm_events, &String.starts_with?(&1["event"], "llm"))
    end

    test "filters by span_id" do
      events = sample_events()

      span_events = Analyzer.filter(events, span_id: "llm-1")

      assert length(span_events) == 2
      assert Enum.all?(span_events, &(&1["span_id"] == "llm-1"))
    end

    test "filters by minimum duration" do
      events = sample_events()

      slow_events = Analyzer.filter(events, min_duration_ms: 100)

      assert length(slow_events) == 3
      assert Enum.all?(slow_events, &(&1["duration_ms"] >= 100))
    end

    test "combines multiple criteria" do
      events = sample_events()

      filtered = Analyzer.filter(events, type: "llm", min_duration_ms: 100)

      assert length(filtered) == 1
      assert Enum.at(filtered, 0)["event"] == "llm.stop"
    end
  end

  describe "slowest/2" do
    test "returns N slowest events" do
      events = sample_events()

      slowest = Analyzer.slowest(events, 3)

      assert length(slowest) == 3
      durations = Enum.map(slowest, & &1["duration_ms"])
      assert durations == [210, 190, 120]
    end

    test "returns all events if fewer than N" do
      events = [
        %{"event" => "test1", "duration_ms" => 100},
        %{"event" => "test2", "duration_ms" => 50}
      ]

      slowest = Analyzer.slowest(events, 5)

      assert length(slowest) == 2
    end

    test "excludes events without duration" do
      events = [
        %{"event" => "start", "timestamp" => "2024-01-01T00:00:00Z"},
        %{"event" => "stop", "duration_ms" => 100}
      ]

      slowest = Analyzer.slowest(events, 5)

      assert length(slowest) == 1
      assert Enum.at(slowest, 0)["event"] == "stop"
    end
  end

  describe "build_tree/1" do
    test "builds span hierarchy" do
      events = sample_events()

      tree = Analyzer.build_tree(events)

      # Should have one root node (run-1)
      assert length(tree) == 1
      root = Enum.at(tree, 0)
      assert root.span_id == "run-1"
      assert root.event_type == "run"

      # Root should have one child (turn-1)
      assert length(root.children) == 1
      turn = Enum.at(root.children, 0)
      assert turn.span_id == "turn-1"

      # Turn should have two children (llm-1, tool-1)
      assert length(turn.children) == 2
    end
  end

  describe "format_timeline/1" do
    test "formats events as timeline string" do
      events = sample_events()

      timeline = Analyzer.format_timeline(events)

      assert String.contains?(timeline, "run.start")
      assert String.contains?(timeline, "llm.stop")
      assert String.contains?(timeline, "(120ms)")
      assert String.contains?(timeline, "get_weather")
    end
  end
end
