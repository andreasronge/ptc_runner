defmodule PtcRunner.Tracer.TimelineTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Tracer
  alias PtcRunner.Tracer.Timeline

  doctest PtcRunner.Tracer.Timeline

  describe "render/1" do
    test "renders timeline with entries" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{duration_ms: 150}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{duration_ms: 30}})
        |> Tracer.finalize()

      output = Timeline.render(tracer)

      assert output =~ "Timeline:"
      assert output =~ "llm_call"
      assert output =~ "tool_call"
      assert output =~ "#"
    end

    test "handles empty trace" do
      tracer = Tracer.new() |> Tracer.finalize()

      output = Timeline.render(tracer)

      assert output =~ "no entries"
    end

    test "shows short trace ID in header" do
      tracer = Tracer.new() |> Tracer.finalize()

      output = Timeline.render(tracer)

      assert output =~ "..."
    end

    test "shows total duration in header" do
      tracer = %Tracer{
        trace_id: "abc12345678901234567890123456789",
        parent_id: nil,
        started_at: ~U[2024-01-15 10:00:00Z],
        entries: [
          %{type: :llm_call, data: %{duration_ms: 100}, timestamp: ~U[2024-01-15 10:00:00Z]}
        ],
        finalized_at: ~U[2024-01-15 10:00:02Z]
      }

      output = Timeline.render(tracer)

      assert output =~ "(total: 2000ms)"
    end

    test "shows offset time for each entry" do
      tracer = %Tracer{
        trace_id: "abc12345678901234567890123456789",
        parent_id: nil,
        started_at: ~U[2024-01-15 10:00:00Z],
        entries: [
          %{type: :llm_call, data: %{duration_ms: 100}, timestamp: ~U[2024-01-15 10:00:00Z]},
          %{type: :tool_call, data: %{duration_ms: 50}, timestamp: ~U[2024-01-15 10:00:01Z]}
        ],
        finalized_at: ~U[2024-01-15 10:00:02Z]
      }

      output = Timeline.render(tracer)

      assert output =~ "0ms"
      assert output =~ "1000ms"
    end

    test "shows duration for each entry" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{duration_ms: 150}})
        |> Tracer.finalize()

      output = Timeline.render(tracer)

      assert output =~ "(150ms)"
    end

    test "defaults entries without duration_ms to 1ms" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{}})
        |> Tracer.finalize()

      output = Timeline.render(tracer)

      assert output =~ "(1ms)"
    end

    test "handles zero total duration" do
      # Edge case: tracer created and finalized in the same microsecond (simulated)
      tracer = %Tracer{
        trace_id: "abc12345678901234567890123456789",
        parent_id: nil,
        started_at: ~U[2024-01-15 10:00:00Z],
        entries: [
          %{type: :llm_call, data: %{duration_ms: 100}, timestamp: ~U[2024-01-15 10:00:00Z]}
        ],
        finalized_at: ~U[2024-01-15 10:00:00Z]
      }

      output = Timeline.render(tracer)

      # Should not crash, and should still render
      assert output =~ "Timeline:"
      assert output =~ "llm_call"
    end

    test "renders multiple entries in order" do
      t1 = ~U[2024-01-15 10:00:00Z]
      t2 = ~U[2024-01-15 10:00:01Z]
      t3 = ~U[2024-01-15 10:00:02Z]

      tracer = %Tracer{
        trace_id: "abc12345678901234567890123456789",
        parent_id: nil,
        started_at: t1,
        entries: [
          %{type: :llm_call, data: %{duration_ms: 500}, timestamp: t1},
          %{type: :tool_call, data: %{duration_ms: 200}, timestamp: t2},
          %{type: :return, data: %{duration_ms: 100}, timestamp: t3}
        ],
        finalized_at: ~U[2024-01-15 10:00:03Z]
      }

      output = Timeline.render(tracer)
      lines = String.split(output, "\n")

      # Find lines with entry types
      entry_lines =
        lines
        |> Enum.filter(&(&1 =~ ~r/(llm_call|tool_call|return)/))

      assert length(entry_lines) == 3

      # Verify order by checking they appear in sequence
      assert Enum.at(entry_lines, 0) =~ "llm_call"
      assert Enum.at(entry_lines, 1) =~ "tool_call"
      assert Enum.at(entry_lines, 2) =~ "return"
    end

    test "bar width is proportional to duration" do
      tracer = %Tracer{
        trace_id: "abc12345678901234567890123456789",
        parent_id: nil,
        started_at: ~U[2024-01-15 10:00:00Z],
        entries: [
          %{type: :llm_call, data: %{duration_ms: 600}, timestamp: ~U[2024-01-15 10:00:00Z]},
          %{type: :tool_call, data: %{duration_ms: 100}, timestamp: ~U[2024-01-15 10:00:00.600Z]}
        ],
        finalized_at: ~U[2024-01-15 10:00:01Z]
      }

      output = Timeline.render(tracer)
      lines = String.split(output, "\n")

      llm_line = Enum.find(lines, &(&1 =~ "llm_call"))
      tool_line = Enum.find(lines, &(&1 =~ "tool_call"))

      # Count hash characters (bars) in each line
      llm_hashes = llm_line |> String.graphemes() |> Enum.count(&(&1 == "#"))
      tool_hashes = tool_line |> String.graphemes() |> Enum.count(&(&1 == "#"))

      # LLM call should have more hashes since it has 6x the duration
      assert llm_hashes > tool_hashes
    end
  end
end
