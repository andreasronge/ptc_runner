defmodule PtcDemo.TraceAnalyzer.ToolsTest do
  use ExUnit.Case, async: true

  alias PtcDemo.TraceAnalyzer.Tools

  @moduletag :tmp_dir

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
              "usage" => %{"turns" => 1, "input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
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
        %{"event" => "run.start", "timestamp" => now, "agent_name" => "test_agent", "span_id" => "run-1"},
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
