defmodule PtcRunner.TracerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Tracer

  doctest PtcRunner.Tracer

  describe "new/0" do
    test "creates tracer with unique 32-char hex trace_id" do
      tracer = Tracer.new()

      assert String.length(tracer.trace_id) == 32
      assert Regex.match?(~r/^[a-f0-9]{32}$/, tracer.trace_id)
    end

    test "creates tracer with nil parent_id" do
      tracer = Tracer.new()

      assert tracer.parent_id == nil
    end

    test "creates tracer with empty entries" do
      tracer = Tracer.new()

      assert tracer.entries == []
    end

    test "creates tracer with started_at timestamp" do
      before = DateTime.utc_now()
      tracer = Tracer.new()
      after_creation = DateTime.utc_now()

      assert DateTime.compare(tracer.started_at, before) in [:gt, :eq]
      assert DateTime.compare(tracer.started_at, after_creation) in [:lt, :eq]
    end

    test "creates tracer with nil finalized_at" do
      tracer = Tracer.new()

      assert tracer.finalized_at == nil
    end
  end

  describe "new/1" do
    test "with parent_id sets parent relationship" do
      parent_id = "parent_trace_abc123"
      tracer = Tracer.new(parent_id: parent_id)

      assert tracer.parent_id == parent_id
    end
  end

  describe "trace_id uniqueness" do
    test "trace IDs are unique across multiple new/0 calls" do
      tracers = for _ <- 1..100, do: Tracer.new()
      trace_ids = Enum.map(tracers, & &1.trace_id)

      assert length(Enum.uniq(trace_ids)) == 100
    end
  end

  describe "add_entry/2" do
    test "returns new tracer with entry prepended" do
      tracer = Tracer.new()
      entry = %{type: :llm_call, data: %{turn: 1}}

      updated = Tracer.add_entry(tracer, entry)

      assert length(updated.entries) == 1
      assert hd(updated.entries).type == :llm_call
    end

    test "preserves previous entries" do
      tracer = Tracer.new()

      tracer = Tracer.add_entry(tracer, %{type: :llm_call, data: %{}})
      tracer = Tracer.add_entry(tracer, %{type: :llm_response, data: %{}})
      tracer = Tracer.add_entry(tracer, %{type: :tool_call, data: %{}})

      assert length(tracer.entries) == 3
    end

    test "adds timestamp automatically if not provided" do
      tracer = Tracer.new()
      entry = %{type: :llm_call, data: %{}}

      updated = Tracer.add_entry(tracer, entry)

      assert %DateTime{} = hd(updated.entries).timestamp
    end

    test "preserves provided timestamp" do
      tracer = Tracer.new()
      custom_time = ~U[2024-01-15 10:30:00Z]
      entry = %{type: :llm_call, data: %{}, timestamp: custom_time}

      updated = Tracer.add_entry(tracer, entry)

      assert hd(updated.entries).timestamp == custom_time
    end

    test "on finalized tracer raises FunctionClauseError" do
      tracer = Tracer.new() |> Tracer.finalize()

      assert_raise FunctionClauseError, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(PtcRunner.Tracer, :add_entry, [tracer, %{type: :llm_call, data: %{}}])
      end
    end
  end

  describe "finalize/1" do
    test "reverses entries to chronological order" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{order: 1}})
        |> Tracer.add_entry(%{type: :llm_response, data: %{order: 2}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{order: 3}})

      result = Tracer.finalize(tracer)

      assert hd(result.entries).data.order == 1
      assert List.last(result.entries).data.order == 3
    end

    test "sets finalized_at timestamp" do
      tracer = Tracer.new()

      before = DateTime.utc_now()
      result = Tracer.finalize(tracer)
      after_finalize = DateTime.utc_now()

      assert is_struct(result.finalized_at, DateTime)
      assert DateTime.compare(result.finalized_at, before) in [:gt, :eq]
      assert DateTime.compare(result.finalized_at, after_finalize) in [:lt, :eq]
    end

    test "on already finalized tracer raises FunctionClauseError" do
      tracer = Tracer.new() |> Tracer.finalize()

      assert_raise FunctionClauseError, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(PtcRunner.Tracer, :finalize, [tracer])
      end
    end
  end

  describe "entries/1" do
    test "returns chronological order when not finalized" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{order: 1}})
        |> Tracer.add_entry(%{type: :llm_response, data: %{order: 2}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{order: 3}})

      entries = Tracer.entries(tracer)

      assert hd(entries).data.order == 1
      assert List.last(entries).data.order == 3
    end

    test "returns chronological order when finalized" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{order: 1}})
        |> Tracer.add_entry(%{type: :llm_response, data: %{order: 2}})
        |> Tracer.finalize()

      entries = Tracer.entries(tracer)

      assert hd(entries).data.order == 1
      assert List.last(entries).data.order == 2
    end
  end

  describe "integration" do
    test "tracer records full execution trace" do
      tracer = Tracer.new()

      tracer =
        tracer
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 1}})
        |> Tracer.add_entry(%{type: :llm_response, data: %{tokens: 100}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{name: "search"}})
        |> Tracer.add_entry(%{type: :tool_result, data: %{result: ["found"]}})
        |> Tracer.add_entry(%{type: :return, data: %{value: %{done: true}}})

      result = Tracer.finalize(tracer)

      assert String.length(result.trace_id) == 32
      assert length(result.entries) == 5
      assert hd(result.entries).type == :llm_call
      assert is_struct(result.finalized_at, DateTime)
      assert is_struct(result.started_at, DateTime)
    end
  end

  describe "merge_parallel/2" do
    test "with empty child list returns parent-only merge" do
      parent =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 1}})
        |> Tracer.finalize()

      merged = Tracer.merge_parallel(parent, [])

      assert merged.root_trace_id == parent.trace_id
      assert merged.metadata.agent_count == 0
      assert merged.metadata.parallel == false
      assert merged.metadata.wall_time_ms == 0
      assert merged.metadata.total_turns == 1
    end

    test "with multiple children creates proper metadata" do
      parent = Tracer.new()

      child1 =
        Tracer.new(parent_id: parent.trace_id)
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 1}})
        |> Tracer.finalize()

      child2 =
        Tracer.new(parent_id: parent.trace_id)
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 1}})
        |> Tracer.finalize()

      merged = Tracer.merge_parallel(parent, [child1, child2])

      assert merged.root_trace_id == parent.trace_id
      assert merged.metadata.agent_count == 2
      assert merged.metadata.parallel == true
      assert merged.metadata.total_turns == 2
    end

    test "sorts all entries by timestamp" do
      parent = Tracer.new()
      t1 = ~U[2024-01-15 10:00:00Z]
      t2 = ~U[2024-01-15 10:00:01Z]
      t3 = ~U[2024-01-15 10:00:02Z]

      child1 =
        Tracer.new(parent_id: parent.trace_id)
        |> Tracer.add_entry(%{type: :llm_call, data: %{order: 1}, timestamp: t1})
        |> Tracer.add_entry(%{type: :llm_call, data: %{order: 3}, timestamp: t3})
        |> Tracer.finalize()

      child2 =
        Tracer.new(parent_id: parent.trace_id)
        |> Tracer.add_entry(%{type: :llm_call, data: %{order: 2}, timestamp: t2})
        |> Tracer.finalize()

      merged = Tracer.merge_parallel(parent, [child1, child2])
      orders = Enum.map(merged.entries, & &1.data.order)

      assert orders == [1, 2, 3]
    end

    test "calculates correct wall_time_ms" do
      parent = Tracer.new()

      child1 = %Tracer{
        trace_id: "child1",
        parent_id: parent.trace_id,
        started_at: ~U[2024-01-15 10:00:00Z],
        entries: [%{type: :llm_call, data: %{}, timestamp: ~U[2024-01-15 10:00:00Z]}],
        finalized_at: ~U[2024-01-15 10:00:05Z]
      }

      child2 = %Tracer{
        trace_id: "child2",
        parent_id: parent.trace_id,
        started_at: ~U[2024-01-15 10:00:01Z],
        entries: [%{type: :llm_call, data: %{}, timestamp: ~U[2024-01-15 10:00:01Z]}],
        finalized_at: ~U[2024-01-15 10:00:03Z]
      }

      merged = Tracer.merge_parallel(parent, [child1, child2])

      # Wall time from earliest start (10:00:00) to latest end (10:00:05) = 5000ms
      assert merged.metadata.wall_time_ms == 5000
    end

    test "handles unfinalized children using current time" do
      parent = Tracer.new()

      child =
        Tracer.new(parent_id: parent.trace_id)
        |> Tracer.add_entry(%{type: :llm_call, data: %{}})

      assert child.finalized_at == nil

      # Should not raise, uses DateTime.utc_now() for unfinalized
      merged = Tracer.merge_parallel(parent, [child])

      assert merged.metadata.agent_count == 1
      assert merged.metadata.wall_time_ms >= 0
    end
  end

  describe "record_nested_call/3" do
    test "adds nested_call entry with tool call and child step data" do
      tracer = Tracer.new()
      tool_call = %{name: "sub_agent", args: %{prompt: "test"}}
      child_step = %{return: "result", turns: [%{turn: 1}]}

      tracer = Tracer.record_nested_call(tracer, tool_call, child_step)
      [entry] = Tracer.entries(tracer)

      assert entry.type == :nested_call
      assert entry.data.name == "sub_agent"
      assert entry.data.args == %{prompt: "test"}
      assert entry.data.result.return == "result"
      assert entry.data.result.nested_turns == [%{turn: 1}]
    end

    test "works with Step struct" do
      tracer = Tracer.new()
      tool_call = %{name: "agent", args: %{}}
      child_step = %PtcRunner.Step{return: "value", turns: [%{turn: 1}]}

      tracer = Tracer.record_nested_call(tracer, tool_call, child_step)
      [entry] = Tracer.entries(tracer)

      assert entry.data.result.return == "value"
      assert entry.data.result.nested_turns == [%{turn: 1}]
    end

    test "on finalized tracer raises FunctionClauseError" do
      tracer = Tracer.new() |> Tracer.finalize()
      tool_call = %{name: "agent", args: %{}}
      child_step = %{return: "result", turns: []}

      assert_raise FunctionClauseError, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(PtcRunner.Tracer, :record_nested_call, [tracer, tool_call, child_step])
      end
    end
  end

  describe "aggregate_usage/1" do
    test "counts LLM calls from tracer" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{}})
        |> Tracer.add_entry(%{type: :llm_call, data: %{}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{}})
        |> Tracer.finalize()

      usage = Tracer.aggregate_usage(tracer)

      assert usage.llm_calls == 2
    end

    test "counts tool calls from tracer" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :tool_call, data: %{}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{}})
        |> Tracer.finalize()

      usage = Tracer.aggregate_usage(tracer)

      assert usage.tool_calls == 3
    end

    test "calculates total turns from tracer" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{}})
        |> Tracer.add_entry(%{type: :llm_response, data: %{}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{}})
        |> Tracer.finalize()

      usage = Tracer.aggregate_usage(tracer)

      assert usage.total_turns == 3
    end

    test "returns agent_count of 1 for single tracer" do
      tracer = Tracer.new() |> Tracer.finalize()

      usage = Tracer.aggregate_usage(tracer)

      assert usage.agent_count == 1
    end

    test "works on merged_trace map" do
      parent = Tracer.new()

      child1 =
        Tracer.new(parent_id: parent.trace_id)
        |> Tracer.add_entry(%{type: :llm_call, data: %{}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{}})
        |> Tracer.finalize()

      child2 =
        Tracer.new(parent_id: parent.trace_id)
        |> Tracer.add_entry(%{type: :llm_call, data: %{}})
        |> Tracer.finalize()

      merged = Tracer.merge_parallel(parent, [child1, child2])
      usage = Tracer.aggregate_usage(merged)

      assert usage.llm_calls == 2
      assert usage.tool_calls == 1
      assert usage.total_turns == 3
      assert usage.agent_count == 2
    end

    test "calculates duration_ms from finalized tracer" do
      tracer = %Tracer{
        trace_id: "test",
        parent_id: nil,
        started_at: ~U[2024-01-15 10:00:00Z],
        entries: [],
        finalized_at: ~U[2024-01-15 10:00:02Z]
      }

      usage = Tracer.aggregate_usage(tracer)

      assert usage.total_duration_ms == 2000
    end

    test "returns 0 duration for unfinalized tracer" do
      tracer = Tracer.new()

      usage = Tracer.aggregate_usage(tracer)

      assert usage.total_duration_ms == 0
    end
  end

  describe "merge parallel traces from Task.async_stream simulation" do
    test "full integration workflow" do
      parent = Tracer.new()

      # Simulate 3 parallel child executions
      child1 =
        Tracer.new(parent_id: parent.trace_id)
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 1}})
        |> Tracer.add_entry(%{type: :return, data: %{result: "a"}})
        |> Tracer.finalize()

      child2 =
        Tracer.new(parent_id: parent.trace_id)
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 1}})
        |> Tracer.add_entry(%{type: :return, data: %{result: "b"}})
        |> Tracer.finalize()

      child3 =
        Tracer.new(parent_id: parent.trace_id)
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 1}})
        |> Tracer.add_entry(%{type: :return, data: %{result: "c"}})
        |> Tracer.finalize()

      merged = Tracer.merge_parallel(parent, [child1, child2, child3])

      assert merged.root_trace_id == parent.trace_id
      assert merged.metadata.agent_count == 3
      assert merged.metadata.parallel == true
      # 2 entries per child
      assert length(merged.entries) == 6

      usage = Tracer.aggregate_usage(merged)
      assert usage.llm_calls == 3
      assert usage.total_turns == 6
      assert usage.agent_count == 3
    end
  end

  describe "total_duration/1" do
    test "calculates duration from finalized tracer" do
      tracer = %Tracer{
        trace_id: "test",
        parent_id: nil,
        started_at: ~U[2024-01-15 10:00:00Z],
        entries: [],
        finalized_at: ~U[2024-01-15 10:00:02Z]
      }

      assert Tracer.total_duration(tracer) == 2000
    end

    test "returns 0 for unfinalized tracer" do
      tracer = Tracer.new()

      assert Tracer.total_duration(tracer) == 0
    end
  end

  describe "find_by_type/2" do
    test "returns matching entries" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 1}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{name: "search"}})
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 2}})
        |> Tracer.finalize()

      llm_entries = Tracer.find_by_type(tracer, :llm_call)

      assert length(llm_entries) == 2
      assert Enum.all?(llm_entries, &(&1.type == :llm_call))
    end

    test "returns empty list when no matches" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{}})
        |> Tracer.finalize()

      assert Tracer.find_by_type(tracer, :tool_call) == []
    end
  end

  describe "llm_calls/1" do
    test "returns LLM call entries" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 1}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{name: "search"}})
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 2}})
        |> Tracer.finalize()

      llm_entries = Tracer.llm_calls(tracer)

      assert length(llm_entries) == 2
      assert Enum.all?(llm_entries, &(&1.type == :llm_call))
    end
  end

  describe "tool_calls/1" do
    test "returns tool call entries" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{name: "search"}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{name: "fetch"}})
        |> Tracer.finalize()

      tool_entries = Tracer.tool_calls(tracer)

      assert length(tool_entries) == 2
      assert Enum.all?(tool_entries, &(&1.type == :tool_call))
    end
  end

  describe "slowest_entries/2" do
    test "returns top N entries by duration" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{duration_ms: 100}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{duration_ms: 50}})
        |> Tracer.add_entry(%{type: :llm_call, data: %{duration_ms: 200}})
        |> Tracer.finalize()

      [slowest | _] = Tracer.slowest_entries(tracer, 1)

      assert slowest.data.duration_ms == 200
    end

    test "returns entries in descending order by duration" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{duration_ms: 100}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{duration_ms: 50}})
        |> Tracer.add_entry(%{type: :llm_call, data: %{duration_ms: 200}})
        |> Tracer.finalize()

      durations =
        tracer
        |> Tracer.slowest_entries(3)
        |> Enum.map(& &1.data.duration_ms)

      assert durations == [200, 100, 50]
    end

    test "excludes entries without duration_ms" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{duration_ms: 100}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{name: "no_duration"}})
        |> Tracer.finalize()

      entries = Tracer.slowest_entries(tracer, 10)

      assert length(entries) == 1
      assert hd(entries).data.duration_ms == 100
    end

    test "returns empty list when no entries have duration" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{}})
        |> Tracer.finalize()

      assert Tracer.slowest_entries(tracer, 3) == []
    end
  end

  describe "usage_summary/1" do
    test "aggregates all stats" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{duration_ms: 100}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{duration_ms: 50}})
        |> Tracer.add_entry(%{type: :llm_call, data: %{duration_ms: 200}})
        |> Tracer.finalize()

      summary = Tracer.usage_summary(tracer)

      assert summary.llm_duration_ms == 300
      assert summary.tool_duration_ms == 50
      assert summary.llm_call_count == 2
      assert summary.tool_call_count == 1
      assert summary.total_entries == 3
    end

    test "handles entries without duration_ms gracefully" do
      tracer =
        Tracer.new()
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 1}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{name: "search"}})
        |> Tracer.finalize()

      summary = Tracer.usage_summary(tracer)

      assert summary.llm_duration_ms == 0
      assert summary.tool_duration_ms == 0
      assert summary.llm_call_count == 1
      assert summary.tool_call_count == 1
    end

    test "includes total_duration_ms from tracer timestamps" do
      tracer = %Tracer{
        trace_id: "test",
        parent_id: nil,
        started_at: ~U[2024-01-15 10:00:00Z],
        entries: [],
        finalized_at: ~U[2024-01-15 10:00:05Z]
      }

      summary = Tracer.usage_summary(tracer)

      assert summary.total_duration_ms == 5000
    end
  end

  describe "max_entries" do
    test "nil max_entries allows unlimited entries" do
      tracer = Tracer.new()

      tracer =
        Enum.reduce(1..100, tracer, fn i, acc ->
          Tracer.add_entry(acc, %{type: :llm_call, data: %{turn: i}})
        end)

      assert tracer.entry_count == 100
      assert length(tracer.entries) == 100
    end

    test "max_entries bounds the number of entries" do
      tracer = Tracer.new(max_entries: 3)

      tracer =
        Enum.reduce(1..10, tracer, fn i, acc ->
          Tracer.add_entry(acc, %{type: :llm_call, data: %{turn: i}})
        end)

      assert tracer.entry_count == 3
      assert length(tracer.entries) == 3
    end

    test "max_entries keeps newest entries and drops oldest" do
      tracer = Tracer.new(max_entries: 3)

      tracer =
        Enum.reduce(1..5, tracer, fn i, acc ->
          Tracer.add_entry(acc, %{type: :llm_call, data: %{turn: i}})
        end)

      # Entries are stored newest-first (prepended), so after finalize they are chronological
      result = Tracer.finalize(tracer)
      turns = Enum.map(result.entries, & &1.data.turn)

      # Newest 3 entries should be kept: turns 3, 4, 5
      assert turns == [3, 4, 5]
    end

    test "max_entries of 1 keeps only the latest entry" do
      tracer = Tracer.new(max_entries: 1)

      tracer =
        tracer
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 1}})
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 2}})
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 3}})

      assert tracer.entry_count == 1
      assert hd(tracer.entries).data.turn == 3
    end

    test "entries/1 returns correct order with max_entries" do
      tracer = Tracer.new(max_entries: 2)

      tracer =
        tracer
        |> Tracer.add_entry(%{type: :llm_call, data: %{turn: 1}})
        |> Tracer.add_entry(%{type: :llm_response, data: %{turn: 2}})
        |> Tracer.add_entry(%{type: :tool_call, data: %{turn: 3}})

      entries = Tracer.entries(tracer)
      turns = Enum.map(entries, & &1.data.turn)

      assert turns == [2, 3]
    end
  end
end
