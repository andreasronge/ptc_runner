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
end
