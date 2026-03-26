defmodule PtcDemo.TraceAnalyzer.ToolsTest do
  use ExUnit.Case, async: true

  alias PtcDemo.TraceAnalyzer.EventStream
  alias PtcDemo.TraceAnalyzer.Tools

  @moduletag :tmp_dir

  describe "trace_metadata/1" do
    test "extracts metadata without loading full file", %{tmp_dir: tmp_dir} do
      trace_file = Path.join(tmp_dir, "meta_test.jsonl")
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      events = [
        %{
          "event" => "trace.start",
          "timestamp" => now,
          "trace_kind" => "benchmark",
          "producer" => "demo.bench",
          "trace_label" => "math_test",
          "query" => "what is 2+2?",
          "model" => "gpt-nano"
        },
        %{"event" => "run.start", "timestamp" => now, "agent_name" => "bench_agent"},
        %{"event" => "turn.start", "turn" => 1},
        %{"event" => "turn.stop", "turn" => 1, "duration_ms" => 120},
        %{
          "event" => "run.stop",
          "duration_ms" => 150,
          "status" => "ok",
          "data" => %{"step" => %{"usage" => %{"turns" => 1, "total_tokens" => 70}}}
        },
        %{"event" => "trace.stop", "duration_ms" => 155}
      ]

      write_jsonl(trace_file, events)

      {:ok, meta} = EventStream.trace_metadata(trace_file)

      assert meta.filename == "meta_test.jsonl"
      assert meta.timestamp == now
      assert meta.agent_name == "bench_agent"
      assert meta.status == "ok"
      assert meta.duration_ms == 155
      assert meta.trace_kind == "benchmark"
      assert meta.producer == "demo.bench"
      assert meta.model == "gpt-nano"
      assert meta.query == "what is 2+2?"
    end

    test "handles escaped quotes in query field", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "escaped.jsonl")
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      events = [
        %{
          "event" => "trace.start",
          "timestamp" => now,
          "trace_kind" => "benchmark",
          "query" => ~s(Find items where name = "widget")
        },
        %{"event" => "run.start", "agent_name" => "agent"},
        %{"event" => "run.stop", "status" => "ok", "duration_ms" => 10},
        %{"event" => "trace.stop", "duration_ms" => 15}
      ]

      write_jsonl(file, events)

      {:ok, meta} = EventStream.trace_metadata(file)
      # query is JSON-decoded from head line, so escapes are handled correctly
      assert meta.query == ~s(Find items where name = "widget")
    end

    test "returns error for missing file", %{tmp_dir: tmp_dir} do
      assert {:error, _} = EventStream.trace_metadata(Path.join(tmp_dir, "nope.jsonl"))
    end

    test "returns error for incomplete trace missing trace.stop", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "truncated.jsonl")
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      events = [
        %{"event" => "trace.start", "timestamp" => now},
        %{"event" => "run.start", "agent_name" => "agent"}
      ]

      write_jsonl(file, events)
      assert {:error, _} = EventStream.trace_metadata(file)
    end

    test "returns error for corrupt JSONL", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "corrupt.jsonl")
      File.write!(file, "not json at all\n{broken")
      assert {:error, _} = EventStream.trace_metadata(file)
    end
  end

  describe "list_traces skips corrupt files" do
    test "excludes incomplete traces from results", %{tmp_dir: tmp_dir} do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      # Valid trace (has trace.stop)
      write_jsonl(Path.join(tmp_dir, "good.jsonl"), [
        %{"event" => "trace.start", "timestamp" => now, "trace_kind" => "benchmark"},
        %{"event" => "run.start", "agent_name" => "agent"},
        %{"event" => "run.stop", "status" => "ok", "duration_ms" => 10},
        %{"event" => "trace.stop", "duration_ms" => 15}
      ])

      # Truncated trace (no run.stop or trace.stop)
      write_jsonl(Path.join(tmp_dir, "bad.jsonl"), [
        %{"event" => "trace.start", "timestamp" => now},
        %{"event" => "run.start", "agent_name" => "agent"}
      ])

      # Corrupt file
      File.write!(Path.join(tmp_dir, "garbage.jsonl"), "not json\n")

      tools = Tools.build(tmp_dir)
      {tool_fn, _meta} = tools["list_traces"]
      {:ok, result} = tool_fn.(%{})

      assert result.count == 1
      assert hd(result.traces).filename == "good.jsonl"
    end
  end

  describe "list_traces uses streaming metadata" do
    test "handles many trace files without loading full contents", %{tmp_dir: tmp_dir} do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      for i <- 1..50 do
        events = [
          %{
            "event" => "trace.start",
            "timestamp" => now,
            "trace_kind" => "benchmark",
            "model" => "test-model"
          },
          %{"event" => "run.start", "agent_name" => "agent_#{i}"},
          %{"event" => "run.stop", "duration_ms" => i * 10, "status" => "ok"},
          %{"event" => "trace.stop", "duration_ms" => i * 10 + 5}
        ]

        write_jsonl(Path.join(tmp_dir, "trace_#{i}.jsonl"), events)
      end

      tools = Tools.build(tmp_dir)
      {tool_fn, _meta} = tools["list_traces"]
      {:ok, result} = tool_fn.(%{"limit" => 5})

      assert result.count == 5
      assert length(result.traces) == 5
    end
  end

  describe "trace_summary extracts run-level failures" do
    test "reports memory_exceeded from run.stop event", %{tmp_dir: tmp_dir} do
      trace_file = Path.join(tmp_dir, "heap_crash.jsonl")
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      events = [
        %{
          "event" => "trace.start",
          "timestamp" => now,
          "trace_id" => "test-trace-1"
        },
        %{
          "event" => "run.start",
          "timestamp" => now,
          "agent_name" => "test_agent",
          "span_id" => "run-1"
        },
        %{
          "event" => "run.stop",
          "timestamp" => now,
          "span_id" => "run-1",
          "duration_ms" => 50,
          "status" => "error",
          "data" => %{
            "fail" => %{
              "reason" => "memory_exceeded",
              "message" => "heap limit 10000000 bytes exceeded"
            },
            "step" => %{
              "usage" => %{
                "turns" => 1,
                "input_tokens" => 10,
                "output_tokens" => 5,
                "total_tokens" => 15
              }
            }
          },
          "input_tokens" => 10,
          "output_tokens" => 5,
          "total_tokens" => 15
        }
      ]

      write_jsonl(trace_file, events)

      tools = Tools.build(tmp_dir)
      {tool_fn, _meta} = tools["trace_summary"]
      {:ok, summary} = tool_fn.(%{"filename" => "heap_crash.jsonl"})

      assert summary.status == "error"
      assert length(summary.errors) == 1

      [error] = summary.errors
      assert error.event == "run.stop"
      assert error.reason == "memory_exceeded"
    end

    test "reports both turn-level and run-level errors", %{tmp_dir: tmp_dir} do
      trace_file = Path.join(tmp_dir, "mixed_errors.jsonl")
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      events = [
        %{"event" => "trace.start", "timestamp" => now, "trace_id" => "test-trace-2"},
        %{
          "event" => "run.start",
          "timestamp" => now,
          "agent_name" => "test_agent",
          "span_id" => "run-1"
        },
        %{
          "event" => "turn.stop",
          "timestamp" => now,
          "turn" => 1,
          "span_id" => "turn-1",
          "parent_span_id" => "run-1",
          "duration_ms" => 30,
          "data" => %{"type" => "error", "reason" => "parse_error"}
        },
        %{
          "event" => "run.stop",
          "timestamp" => now,
          "span_id" => "run-1",
          "duration_ms" => 50,
          "status" => "error",
          "data" => %{
            "fail" => %{"reason" => "memory_exceeded", "message" => "heap limit exceeded"},
            "step" => %{"usage" => %{"turns" => 1, "total_tokens" => 15}}
          },
          "input_tokens" => 10,
          "output_tokens" => 5,
          "total_tokens" => 15
        }
      ]

      write_jsonl(trace_file, events)

      tools = Tools.build(tmp_dir)
      {tool_fn, _meta} = tools["trace_summary"]
      {:ok, summary} = tool_fn.(%{"filename" => "mixed_errors.jsonl"})

      assert length(summary.errors) == 2
      reasons = Enum.map(summary.errors, & &1.reason)
      assert "parse_error" in reasons
      assert "memory_exceeded" in reasons
    end
  end

  defp write_jsonl(path, events) do
    content = Enum.map_join(events, "\n", &Jason.encode!/1)
    File.write!(path, content)
  end
end
