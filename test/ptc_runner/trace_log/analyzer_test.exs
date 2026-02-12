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

    test "excludes trace.start from output" do
      events = sample_events()
      timeline = Analyzer.format_timeline(events)

      refute String.contains?(timeline, "trace.start")
    end
  end

  # Helper to write a JSONL trace file from a list of event maps
  defp write_trace!(path, events) do
    content = Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n"
    File.write!(path, content)
    path
  end

  # Minimal trace events for tree tests (trace.start/stop + run.start/stop + llm span)
  defp tree_trace_events(trace_id, opts \\ []) do
    duration_ms = Keyword.get(opts, :duration_ms, 500)
    extra_events = Keyword.get(opts, :extra_events, [])

    [
      %{
        "event" => "trace.start",
        "trace_id" => trace_id,
        "timestamp" => "2025-01-15T10:00:00.000Z",
        "meta" => %{}
      },
      %{
        "event" => "run.start",
        "span_id" => "run-#{trace_id}",
        "parent_span_id" => nil,
        "timestamp" => "2025-01-15T10:00:00.010Z",
        "metadata" => %{}
      },
      %{
        "event" => "turn.start",
        "span_id" => "turn-#{trace_id}",
        "parent_span_id" => "run-#{trace_id}",
        "timestamp" => "2025-01-15T10:00:00.020Z",
        "metadata" => %{"turn_number" => 1}
      },
      %{
        "event" => "llm.start",
        "span_id" => "llm-#{trace_id}",
        "parent_span_id" => "turn-#{trace_id}",
        "timestamp" => "2025-01-15T10:00:00.030Z",
        "metadata" => %{"messages" => []}
      },
      %{
        "event" => "llm.stop",
        "span_id" => "llm-#{trace_id}",
        "parent_span_id" => "turn-#{trace_id}",
        "timestamp" => "2025-01-15T10:00:00.400Z",
        "duration_ms" => duration_ms - 100,
        "metadata" => %{"response" => "(return 42)"},
        "measurements" => %{"tokens" => 15}
      }
    ] ++
      extra_events ++
      [
        %{
          "event" => "turn.stop",
          "span_id" => "turn-#{trace_id}",
          "parent_span_id" => "run-#{trace_id}",
          "timestamp" => "2025-01-15T10:00:00.450Z",
          "duration_ms" => duration_ms - 50,
          "metadata" => %{"turn_number" => 1, "tokens" => 15}
        },
        %{
          "event" => "run.stop",
          "span_id" => "run-#{trace_id}",
          "parent_span_id" => nil,
          "timestamp" => "2025-01-15T10:00:00.490Z",
          "duration_ms" => duration_ms - 10,
          "metadata" => %{
            "status" => "ok",
            "step" => %{
              "usage" => %{
                "turns" => 1,
                "input_tokens" => 10,
                "output_tokens" => 5,
                "total_tokens" => 15
              }
            }
          }
        },
        %{
          "event" => "trace.stop",
          "trace_id" => trace_id,
          "timestamp" => "2025-01-15T10:00:00.500Z",
          "duration_ms" => duration_ms
        }
      ]
  end

  describe "load_tree/1" do
    test "loads single trace file into tree structure", %{tmp_dir: dir} do
      path = Path.join(dir, "trace.jsonl")
      write_trace!(path, tree_trace_events("single-trace"))

      {:ok, tree} = Analyzer.load_tree(path)

      assert tree.path == path
      assert tree.trace_id == "single-trace"
      assert tree.children == []
      assert tree.summary.duration_ms == 490
      assert tree.summary.llm_calls == 1
      assert tree.summary.status == "ok"
      assert length(tree.events) == 8
    end

    test "recursively loads child traces via tool.stop child_trace_id", %{tmp_dir: dir} do
      # Write child trace
      child_id = "child-001"
      child_path = Path.join(dir, "#{child_id}.jsonl")
      write_trace!(child_path, tree_trace_events(child_id, duration_ms: 200))

      # Write parent trace with a tool.stop referencing the child
      tool_events = [
        %{
          "event" => "tool.start",
          "span_id" => "tool-sub",
          "parent_span_id" => "turn-parent",
          "timestamp" => "2025-01-15T10:00:00.100Z",
          "metadata" => %{"tool_name" => "sub_agent", "args" => %{}}
        },
        %{
          "event" => "tool.stop",
          "span_id" => "tool-sub",
          "parent_span_id" => "turn-parent",
          "timestamp" => "2025-01-15T10:00:00.300Z",
          "duration_ms" => 200,
          "metadata" => %{"tool_name" => "sub_agent", "child_trace_id" => child_id}
        }
      ]

      parent_path = Path.join(dir, "parent.jsonl")
      write_trace!(parent_path, tree_trace_events("parent", extra_events: tool_events))

      {:ok, tree} = Analyzer.load_tree(parent_path)

      assert tree.trace_id == "parent"
      assert length(tree.children) == 1

      [child] = tree.children
      assert child.trace_id == child_id
      assert child.summary.llm_calls == 1
      assert child.summary.duration_ms == 190
    end

    test "detects cycles and skips cyclic child", %{tmp_dir: dir} do
      trace_id = "cycle-trace"

      tool_events = [
        %{
          "event" => "tool.start",
          "span_id" => "tool-self",
          "parent_span_id" => "turn-#{trace_id}",
          "timestamp" => "2025-01-15T10:00:00.100Z",
          "metadata" => %{"tool_name" => "self_ref", "args" => %{}}
        },
        %{
          "event" => "tool.stop",
          "span_id" => "tool-self",
          "parent_span_id" => "turn-#{trace_id}",
          "timestamp" => "2025-01-15T10:00:00.200Z",
          "duration_ms" => 100,
          "metadata" => %{"tool_name" => "self_ref", "child_trace_id" => trace_id}
        }
      ]

      path = Path.join(dir, "#{trace_id}.jsonl")
      write_trace!(path, tree_trace_events(trace_id, extra_events: tool_events))

      {:ok, tree} = Analyzer.load_tree(path)

      assert tree.trace_id == trace_id
      assert tree.children == []
    end

    test "returns error for non-existent file", %{tmp_dir: dir} do
      path = Path.join(dir, "nonexistent.jsonl")
      assert {:error, _reason} = Analyzer.load_tree(path)
    end
  end

  describe "list_tree/1" do
    test "returns all file paths in the tree", %{tmp_dir: dir} do
      child_id = "list-child"
      child_path = Path.join(dir, "#{child_id}.jsonl")
      write_trace!(child_path, tree_trace_events(child_id))

      tool_events = [
        %{
          "event" => "tool.start",
          "span_id" => "tool-x",
          "parent_span_id" => "turn-list-parent",
          "timestamp" => "2025-01-15T10:00:00.100Z",
          "metadata" => %{"tool_name" => "sub", "args" => %{}}
        },
        %{
          "event" => "tool.stop",
          "span_id" => "tool-x",
          "parent_span_id" => "turn-list-parent",
          "timestamp" => "2025-01-15T10:00:00.200Z",
          "duration_ms" => 100,
          "metadata" => %{"tool_name" => "sub", "child_trace_id" => child_id}
        }
      ]

      parent_path = Path.join(dir, "parent.jsonl")
      write_trace!(parent_path, tree_trace_events("list-parent", extra_events: tool_events))

      {:ok, tree} = Analyzer.load_tree(parent_path)
      paths = Analyzer.list_tree(tree)

      assert length(paths) == 2
      assert parent_path in paths
      assert child_path in paths
    end
  end

  describe "delete_tree/1" do
    test "removes all trace files in the tree", %{tmp_dir: dir} do
      child_id = "del-child"
      child_path = Path.join(dir, "#{child_id}.jsonl")
      write_trace!(child_path, tree_trace_events(child_id))

      tool_events = [
        %{
          "event" => "tool.start",
          "span_id" => "tool-d",
          "parent_span_id" => "turn-del-parent",
          "timestamp" => "2025-01-15T10:00:00.100Z",
          "metadata" => %{"tool_name" => "sub", "args" => %{}}
        },
        %{
          "event" => "tool.stop",
          "span_id" => "tool-d",
          "parent_span_id" => "turn-del-parent",
          "timestamp" => "2025-01-15T10:00:00.200Z",
          "duration_ms" => 100,
          "metadata" => %{"tool_name" => "sub", "child_trace_id" => child_id}
        }
      ]

      parent_path = Path.join(dir, "parent.jsonl")
      write_trace!(parent_path, tree_trace_events("del-parent", extra_events: tool_events))

      {:ok, tree} = Analyzer.load_tree(parent_path)
      {:ok, 2} = Analyzer.delete_tree(tree)

      refute File.exists?(parent_path)
      refute File.exists?(child_path)
    end
  end

  describe "export_chrome_trace/2" do
    test "exports valid Chrome trace JSON file", %{tmp_dir: dir} do
      trace_path = Path.join(dir, "trace.jsonl")
      write_trace!(trace_path, tree_trace_events("chrome-test"))

      {:ok, tree} = Analyzer.load_tree(trace_path)
      output_path = Path.join(dir, "trace.json")
      assert :ok = Analyzer.export_chrome_trace(tree, output_path)

      assert File.exists?(output_path)
      chrome = output_path |> File.read!() |> Jason.decode!()

      assert is_list(chrome["traceEvents"])
      assert chrome["metadata"]["source"] == "PtcRunner.TraceLog"
      assert chrome["metadata"]["trace_id"] == "chrome-test"
    end

    test "chrome trace events have required fields (name, ph, ts, pid, tid)", %{tmp_dir: dir} do
      trace_path = Path.join(dir, "trace.jsonl")
      write_trace!(trace_path, tree_trace_events("chrome-fields"))

      {:ok, tree} = Analyzer.load_tree(trace_path)
      output_path = Path.join(dir, "trace.json")
      Analyzer.export_chrome_trace(tree, output_path)

      %{"traceEvents" => events} = output_path |> File.read!() |> Jason.decode!()

      for event <- events do
        assert Map.has_key?(event, "name")
        assert Map.has_key?(event, "ph")
        assert Map.has_key?(event, "ts")
        assert Map.has_key?(event, "pid")
        assert Map.has_key?(event, "tid")
        assert event["ph"] == "X"
      end
    end

    test "includes recognizable span names", %{tmp_dir: dir} do
      trace_path = Path.join(dir, "trace.jsonl")
      write_trace!(trace_path, tree_trace_events("chrome-names"))

      {:ok, tree} = Analyzer.load_tree(trace_path)
      output_path = Path.join(dir, "trace.json")
      Analyzer.export_chrome_trace(tree, output_path)

      %{"traceEvents" => events} = output_path |> File.read!() |> Jason.decode!()
      names = Enum.map(events, & &1["name"])

      # Main trace span
      assert Enum.any?(names, &String.starts_with?(&1, "trace-"))
      # Internal spans
      assert "Turn 1" in names
      assert "LLM call" in names
    end

    test "child traces get different thread IDs than parent", %{tmp_dir: dir} do
      child_id = "chrome-child"
      child_path = Path.join(dir, "#{child_id}.jsonl")
      write_trace!(child_path, tree_trace_events(child_id))

      tool_events = [
        %{
          "event" => "tool.start",
          "span_id" => "tool-c",
          "parent_span_id" => "turn-chrome-parent",
          "timestamp" => "2025-01-15T10:00:00.100Z",
          "metadata" => %{"tool_name" => "sub", "args" => %{}}
        },
        %{
          "event" => "tool.stop",
          "span_id" => "tool-c",
          "parent_span_id" => "turn-chrome-parent",
          "timestamp" => "2025-01-15T10:00:00.200Z",
          "duration_ms" => 100,
          "metadata" => %{"tool_name" => "sub", "child_trace_id" => child_id}
        }
      ]

      parent_path = Path.join(dir, "parent.jsonl")
      write_trace!(parent_path, tree_trace_events("chrome-parent", extra_events: tool_events))

      {:ok, tree} = Analyzer.load_tree(parent_path)
      output_path = Path.join(dir, "trace.json")
      Analyzer.export_chrome_trace(tree, output_path)

      %{"traceEvents" => events} = output_path |> File.read!() |> Jason.decode!()
      tids = events |> Enum.map(& &1["tid"]) |> Enum.uniq()

      assert length(tids) > 1
    end
  end

  describe "format_tree/1" do
    test "formats single-node tree with duration and trace ID", %{tmp_dir: dir} do
      path = Path.join(dir, "trace.jsonl")
      write_trace!(path, tree_trace_events("fmt-single"))

      {:ok, tree} = Analyzer.load_tree(path)
      output = Analyzer.format_tree(tree)

      assert output =~ "490ms"
      assert output =~ "ok"
      assert output =~ "fmt-sing"
    end

    test "formats parent-child tree with connectors", %{tmp_dir: dir} do
      child_id = "fmt-child"
      child_path = Path.join(dir, "#{child_id}.jsonl")
      write_trace!(child_path, tree_trace_events(child_id))

      tool_events = [
        %{
          "event" => "tool.start",
          "span_id" => "tool-f",
          "parent_span_id" => "turn-fmt-parent",
          "timestamp" => "2025-01-15T10:00:00.100Z",
          "metadata" => %{"tool_name" => "sub", "args" => %{}}
        },
        %{
          "event" => "tool.stop",
          "span_id" => "tool-f",
          "parent_span_id" => "turn-fmt-parent",
          "timestamp" => "2025-01-15T10:00:00.200Z",
          "duration_ms" => 100,
          "metadata" => %{"tool_name" => "sub", "child_trace_id" => child_id}
        }
      ]

      parent_path = Path.join(dir, "parent.jsonl")
      write_trace!(parent_path, tree_trace_events("fmt-parent", extra_events: tool_events))

      {:ok, tree} = Analyzer.load_tree(parent_path)
      output = Analyzer.format_tree(tree)

      assert output =~ "fmt-pare"
      assert output =~ "fmt-chil"
      assert output =~ "└─"
    end
  end
end
