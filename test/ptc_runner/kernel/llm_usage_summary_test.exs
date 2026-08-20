defmodule PtcRunner.Kernel.LLMUsageSummaryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.LLMUsageSummary
  alias PtcRunner.TestSupport.TestHelpers

  test "terminal summaries are identical for decoded and in-memory event representations" do
    snapshot = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:writer/model")

    decoded = [
      event(1, "run-started", %{"missions" => %{}, "connector_snapshots" => [snapshot]}),
      event(2, "capability-stopped", %{
        "environment" => "workflow",
        "name" => "llm-request",
        "alias" => "writer",
        "installation_revision" => "stable-v1",
        "status" => "ok",
        "usage" => %{"input" => 3}
      }),
      event(3, "run-stopped", %{"outcome" => "ok"})
    ]

    in_memory = [
      memory_event(1, "run-started", %{missions: %{}, connector_snapshots: [snapshot]}),
      memory_event(2, "capability-stopped", %{
        environment: :workflow,
        name: "llm-request",
        alias: "writer",
        installation_revision: "stable-v1",
        status: :ok,
        usage: %{input: 3}
      }),
      memory_event(3, "run-stopped", %{outcome: :ok})
    ]

    assert {:ok, summary} = LLMUsageSummary.terminal(decoded)
    assert {:ok, ^summary} = LLMUsageSummary.terminal(in_memory)
    assert get_in(summary, ["llm_usage", Access.at(0), "usage"]) == %{"input" => 3}
    refute Map.has_key?(get_in(summary, ["llm_usage", Access.at(0), "usage"]), "total_cost")

    assert get_in(summary, ["llm_usage_by_model", Access.at(0), "resolved_model"]) ==
             "openrouter:writer/model"
  end

  test "malformed terminal batches fail closed" do
    valid = [
      event(1, "run-started", %{"missions" => %{}}),
      event(2, "run-stopped", %{"outcome" => "ok"})
    ]

    malformed = [
      [hd(valid), Map.put(List.last(valid), "run_id", "other-run")],
      tl(valid),
      [hd(valid), %{hd(valid) | "sequence" => 2}, %{List.last(valid) | "sequence" => 3}],
      Enum.drop(valid, -1),
      [Map.delete(hd(valid), "data"), List.last(valid)]
    ]

    for events <- malformed do
      assert {:error, :invalid_event_batch} = LLMUsageSummary.terminal(events)
    end
  end

  test "fixed command aggregation bounds fail closed" do
    assert {:error, :invalid_event_batch} =
             LLMUsageSummary.terminal(List.duplicate(%{}, 65_537))

    calls =
      for index <- 1..129 do
        event(index + 1, "capability-stopped", %{
          "environment" => "workflow",
          "name" => "llm-request",
          "alias" => "a#{String.pad_leading(Integer.to_string(index), 3, "0")}",
          "installation_revision" => "stable-v1",
          "status" => "error"
        })
      end

    events =
      [event(1, "run-started", %{"missions" => %{}})] ++
        calls ++ [event(131, "run-stopped", %{"outcome" => "error"})]

    assert {:error, :invalid_event_batch} = LLMUsageSummary.terminal(events)
  end

  test "ambiguous public snapshots retain alias usage as unattributed" do
    snapshot = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:writer/model")

    events = [
      event(1, "run-started", %{
        "missions" => %{},
        "connector_snapshots" => [snapshot, snapshot]
      }),
      event(2, "capability-stopped", %{
        "environment" => "workflow",
        "name" => "llm-request",
        "alias" => "writer",
        "installation_revision" => "stable-v1",
        "status" => "ok",
        "usage" => %{"input" => 1}
      }),
      event(3, "run-stopped", %{"outcome" => "ok"})
    ]

    assert {:ok,
            %{
              "llm_usage" => [%{"calls" => 1}],
              "llm_usage_by_model" => [],
              "unattributed_model_calls" => 1
            }} = LLMUsageSummary.terminal(events)
  end

  test "mixed priced and unpriced calls omit an incomplete aggregate cost" do
    snapshot = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:writer/model")

    events = [
      event(1, "run-started", %{"missions" => %{}, "connector_snapshots" => [snapshot]}),
      llm_stopped_event(2, %{"input" => 3, "total_cost" => 0.25}),
      llm_stopped_event(3, %{"input" => 5}),
      event(4, "run-stopped", %{"outcome" => "ok"})
    ]

    assert {:ok, summary} = LLMUsageSummary.terminal(events)

    for rows <- [summary["llm_usage"], summary["llm_usage_by_model"]] do
      assert [%{"usage_calls" => 2, "missing_usage_calls" => 0, "usage" => usage} = row] = rows
      assert usage == %{"input" => 8}
      refute Map.has_key?(row, :cost_complete?)
    end
  end

  test "run totals publish only metrics reported by every successful call" do
    complete = [
      llm_stopped_event(1, %{"input" => 3, "output" => 2, "total_cost" => 0.25}),
      llm_stopped_event(2, %{"input" => 5, "output" => 4, "total_cost" => 0.5}),
      event(3, "run-stopped", %{"outcome" => "ok"})
    ]

    assert LLMUsageSummary.totals(complete) == %{
             "input" => 8,
             "output" => 6,
             "total_cost" => 0.75
           }

    partially_reported = [
      llm_stopped_event(1, %{"input" => 3, "output" => 2, "total_cost" => 0.25}),
      llm_stopped_event(2, %{"input" => 5}),
      event(3, "run-stopped", %{"outcome" => "ok"})
    ]

    assert LLMUsageSummary.totals(partially_reported) == %{"input" => 8}
  end

  test "run totals are unavailable when usage or trace events are missing" do
    missing_usage =
      event(1, "capability-stopped", %{
        "environment" => "workflow",
        "name" => "llm-request",
        "alias" => "writer",
        "installation_revision" => "stable-v1",
        "status" => "ok"
      })

    assert LLMUsageSummary.totals([
             missing_usage,
             event(2, "run-stopped", %{"outcome" => "ok"})
           ]) == %{}

    assert LLMUsageSummary.totals([llm_stopped_event(1, %{"input" => 3})]) == %{}

    dropped = [
      llm_stopped_event(1, %{"input" => 3, "output" => 2, "total_cost" => 0.25}),
      event(2, "events-dropped", %{"counts" => %{"capability-stopped" => 1}}),
      event(3, "run-stopped", %{"outcome" => "ok"})
    ]

    assert LLMUsageSummary.totals(dropped) == %{}
  end

  test "the live accumulator names empty, unpriced, incomplete, and available spend" do
    empty = %{}
    assert LLMUsageSummary.spend(empty) == %{"state" => "empty"}

    failed =
      LLMUsageSummary.accumulate(empty, "writer", "stable-v1", :error, %{
        "input" => 3,
        "total_cost" => 0.25
      })

    assert LLMUsageSummary.spend(failed) == %{"state" => "empty"}

    unpriced =
      LLMUsageSummary.accumulate(empty, "writer", "stable-v1", :ok, %{
        "input" => 3,
        "output" => 2
      })

    assert LLMUsageSummary.spend(unpriced) == %{
             "state" => "unpriced",
             "input" => 3,
             "output" => 2
           }

    incomplete = LLMUsageSummary.accumulate(empty, "writer", "stable-v1", :ok, nil)
    assert LLMUsageSummary.spend(incomplete) == %{"state" => "incomplete"}

    invalid =
      LLMUsageSummary.accumulate(empty, "writer", "stable-v1", :ok, %{"content" => "nope"})

    assert LLMUsageSummary.spend(invalid) == %{"state" => "incomplete"}

    available =
      empty
      |> LLMUsageSummary.accumulate("writer", "stable-v1", :ok, %{
        "input" => 3,
        "output" => 2,
        "total_cost" => 0.25
      })
      |> LLMUsageSummary.accumulate("writer", "stable-v1", :error, nil)
      |> LLMUsageSummary.accumulate("other", "stable-v1", :ok, %{
        "input" => 5,
        "output" => 4,
        "total_cost" => 0.5
      })

    assert LLMUsageSummary.spend(available) == %{
             "state" => "available",
             "input" => 8,
             "output" => 6,
             "total_cost" => 0.75
           }
  end

  test "a missing successful usage withholds priced totals even when another call is priced" do
    mixed =
      %{}
      |> LLMUsageSummary.accumulate("writer", "stable-v1", :ok, %{
        "input" => 3,
        "output" => 2,
        "total_cost" => 0.25
      })
      |> LLMUsageSummary.accumulate("writer", "stable-v1", :ok, nil)

    assert LLMUsageSummary.spend(mixed) == %{"state" => "incomplete"}
  end

  defp event(sequence, type, data) do
    %{
      "schema_version" => 2,
      "run_id" => "summary-run",
      "trace_id" => "trace-summary-run",
      "sequence" => sequence,
      "timestamp" => "2026-08-15T10:00:00Z",
      "type" => type,
      "data" => data
    }
  end

  defp memory_event(sequence, type, data) do
    %{
      schema_version: 2,
      run_id: "summary-run",
      trace_id: "trace-summary-run",
      sequence: sequence,
      timestamp: ~U[2026-08-15 10:00:00Z],
      type: type,
      data: data
    }
  end

  defp llm_stopped_event(sequence, usage) do
    event(sequence, "capability-stopped", %{
      "environment" => "workflow",
      "name" => "llm-request",
      "alias" => "writer",
      "installation_revision" => "stable-v1",
      "status" => "ok",
      "usage" => usage
    })
  end
end
