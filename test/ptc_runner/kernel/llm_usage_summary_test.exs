defmodule PtcRunner.Kernel.LLMUsageSummaryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.LLMUsageSummary
  alias PtcRunner.TestSupport.TestHelpers

  test "terminal summaries are identical for decoded and in-memory event representations" do
    snapshot = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:writer/model")

    decoded = [
      event(1, "run-started", %{"missions" => %{}, "connector_snapshots" => [snapshot]}),
      llm_started_event(2, "capability-1"),
      event(3, "capability-stopped", %{
        "environment" => "workflow",
        "name" => "llm-request",
        "capability_id" => "capability-1",
        "alias" => "writer",
        "installation_revision" => "stable-v1",
        "status" => "ok",
        "usage" => %{"input" => 3}
      }),
      event(4, "run-stopped", %{"outcome" => "ok"})
    ]

    in_memory = [
      memory_event(1, "run-started", %{missions: %{}, connector_snapshots: [snapshot]}),
      memory_event(2, "capability-started", %{
        environment: :workflow,
        name: "llm-request",
        capability_id: "capability-1",
        alias: "writer",
        installation_revision: "stable-v1"
      }),
      memory_event(3, "capability-stopped", %{
        environment: :workflow,
        name: "llm-request",
        capability_id: "capability-1",
        alias: "writer",
        installation_revision: "stable-v1",
        status: :ok,
        usage: %{input: 3}
      }),
      memory_event(4, "run-stopped", %{outcome: :ok})
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
        alias_name = "a#{String.pad_leading(Integer.to_string(index), 3, "0")}"
        capability_id = "capability-#{index}"
        extra = %{"alias" => alias_name}

        [
          llm_started_event(index * 2, capability_id, extra),
          llm_failed_event(index * 2 + 1, capability_id, extra)
        ]
      end

    events =
      [event(1, "run-started", %{"missions" => %{}})] ++
        List.flatten(calls) ++ [event(260, "run-stopped", %{"outcome" => "error"})]

    assert {:error, :invalid_event_batch} = LLMUsageSummary.terminal(events)
  end

  test "ambiguous public snapshots retain alias usage as unattributed" do
    snapshot = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:writer/model")

    events = [
      event(1, "run-started", %{
        "missions" => %{},
        "connector_snapshots" => [snapshot, snapshot]
      }),
      llm_started_event(2, "capability-ambiguous"),
      llm_stopped_event(3, "capability-ambiguous", %{"input" => 1}),
      event(4, "run-stopped", %{"outcome" => "ok"})
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
      llm_started_event(2, "capability-priced"),
      llm_stopped_event(3, "capability-priced", %{"input" => 3, "total_cost" => 0.25}),
      llm_started_event(4, "capability-unpriced"),
      llm_stopped_event(5, "capability-unpriced", %{"input" => 5}),
      event(6, "run-stopped", %{"outcome" => "ok"})
    ]

    assert {:ok, summary} = LLMUsageSummary.terminal(events)

    for rows <- [summary["llm_usage"], summary["llm_usage_by_model"]] do
      assert [%{"usage_calls" => 2, "missing_usage_calls" => 0, "usage" => usage} = row] = rows
      assert usage == %{"input" => 8}
      refute Map.has_key?(row, :cost_complete?)
    end
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

    partial_tokens =
      LLMUsageSummary.accumulate(empty, "writer", "stable-v1", :ok, %{"input" => 3})

    assert LLMUsageSummary.spend(partial_tokens) == %{"state" => "incomplete"}

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
             "total_cost" => %{"currency" => "USD", "microunits" => 750_000}
           }
  end

  test "the spend projection validator accepts only the five exact public shapes" do
    valid = [
      %{"state" => "empty"},
      %{"state" => "incomplete"},
      %{"state" => "overflow"},
      %{"state" => "unpriced", "input" => 0, "output" => 2},
      %{
        "state" => "available",
        "input" => 3,
        "output" => 4,
        "total_cost" => %{"currency" => "USD", "microunits" => 0}
      }
    ]

    for spend <- valid do
      assert {:ok, ^spend} = LLMUsageSummary.validate_spend(spend)
    end

    for invalid <- [
          nil,
          %{},
          %{"state" => "empty", "total_cost" => 0},
          %{"state" => "unpriced", "input" => 1},
          %{"state" => "unpriced", "input" => 1, "output" => 2, "total_cost" => 0},
          %{"state" => "available", "input" => 1, "output" => 2},
          %{"state" => "available", "input" => 1, "output" => 2, "total_cost" => nil},
          %{"state" => "available", "input" => -1, "output" => 2, "total_cost" => 0},
          %{"state" => "available", "input" => 1, "output" => 2, "total_cost" => -0.1},
          %{state: "empty"}
        ] do
      assert {:error, :invalid_llm_spend} = LLMUsageSummary.validate_spend(invalid)
    end
  end

  test "an explicit null cost is invalid rather than silently unpriced" do
    counters =
      %{}
      |> LLMUsageSummary.accumulate("writer", "stable-v1", :ok, %{
        "input" => 3,
        "output" => 2,
        "total_cost" => nil
      })
      |> LLMUsageSummary.accumulate("writer", "stable-v1", :ok, %{
        "input" => 5,
        "output" => 4,
        "total_cost" => 0.25
      })

    assert LLMUsageSummary.spend(counters) == %{"state" => "incomplete"}
  end

  test "a provider response above the fixed-point ceiling is incomplete" do
    per_response_max = 9_007_199_254_740_991

    counters =
      %{}
      |> LLMUsageSummary.accumulate("writer", "stable-v1", :ok, %{
        "input" => per_response_max,
        "output" => per_response_max,
        "total_cost" => 1.0e12
      })
      |> LLMUsageSummary.accumulate("writer", "stable-v1", :ok, %{
        "input" => per_response_max,
        "output" => per_response_max,
        "total_cost" => 1.0e12
      })

    assert LLMUsageSummary.spend(counters) == %{"state" => "incomplete"}
  end

  test "usage rows saturate and the spend projection reports aggregate overflow" do
    maximum = 9_007_199_254_740_991
    cost = %{"currency" => "USD", "microunits" => maximum}

    counters =
      %{}
      |> LLMUsageSummary.accumulate("writer", "stable-v1", :ok, %{
        "input" => maximum,
        "output" => maximum,
        "total_cost" => cost
      })
      |> LLMUsageSummary.accumulate("writer", "stable-v1", :ok, %{
        "input" => 1,
        "output" => 1,
        "total_cost" => %{"currency" => "USD", "microunits" => 1}
      })

    assert LLMUsageSummary.spend(counters) == %{"state" => "overflow"}

    assert [row] =
             LLMUsageSummary.alias_rows([
               {"writer", "stable-v1",
                %{
                  "input" => maximum,
                  "output" => maximum,
                  "total_cost" => cost
                }},
               {"writer", "stable-v1",
                %{
                  "input" => 1,
                  "output" => 1,
                  "total_cost" => %{"currency" => "USD", "microunits" => 1}
                }}
             ])

    assert row["usage_overflow"] == true

    assert row["usage"] == %{
             "input" => maximum,
             "output" => maximum,
             "total_cost" => cost
           }

    assert {:ok, %{"state" => "overflow"}} =
             LLMUsageSummary.validate_spend(%{"state" => "overflow"})
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

  test "an unmatched LLM start is an observed call with unknown usage" do
    snapshot = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:writer/model")

    events = [
      event(1, "run-started", %{"missions" => %{}, "connector_snapshots" => [snapshot]}),
      llm_started_event(2, "capability-open"),
      event(3, "run-stopped", %{"outcome" => "timeout"})
    ]

    assert {:ok, summary} = LLMUsageSummary.terminal(events)
    assert summary["unattributed_model_calls"] == 0

    for rows <- [summary["llm_usage"], summary["llm_usage_by_model"]] do
      assert [
               %{
                 "calls" => 1,
                 "successful_calls" => 0,
                 "usage_calls" => 0,
                 "missing_usage_calls" => 1,
                 "usage" => %{}
               } = row
             ] = rows

      refute Map.has_key?(row["usage"], "total_cost")
    end

    assert hd(summary["llm_usage"])["alias"] == "writer"
    assert hd(summary["llm_usage"])["installation_revision"] == "stable-v1"
    assert hd(summary["llm_usage_by_model"])["resolved_model"] == "openrouter:writer/model"
  end

  test "matched successful and failed LLM calls keep their current counters" do
    snapshot = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:writer/model")

    events = [
      event(1, "run-started", %{"missions" => %{}, "connector_snapshots" => [snapshot]}),
      llm_started_event(2, "capability-ok"),
      llm_stopped_event(3, "capability-ok", %{"input" => 4, "output" => 2, "total_cost" => 0.1}),
      llm_started_event(4, "capability-error"),
      llm_failed_event(5, "capability-error"),
      event(6, "run-stopped", %{"outcome" => "error"})
    ]

    assert {:ok, summary} = LLMUsageSummary.terminal(events)

    for rows <- [summary["llm_usage"], summary["llm_usage_by_model"]] do
      assert [
               %{
                 "calls" => 2,
                 "successful_calls" => 1,
                 "usage_calls" => 1,
                 "missing_usage_calls" => 0,
                 "usage_overflow" => false,
                 "usage" => %{
                   "input" => 4,
                   "output" => 2,
                   "total_cost" => %{"currency" => "USD", "microunits" => 100_000}
                 }
               }
             ] = rows
    end
  end

  test "mixed measured and unmatched calls retain tokens and omit total_cost" do
    snapshot = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:writer/model")

    events = [
      event(1, "run-started", %{"missions" => %{}, "connector_snapshots" => [snapshot]}),
      llm_started_event(2, "capability-measured"),
      llm_stopped_event(3, "capability-measured", %{
        "input" => 6,
        "output" => 1,
        "total_cost" => 0.4
      }),
      llm_started_event(4, "capability-open"),
      event(5, "run-stopped", %{"outcome" => "timeout"})
    ]

    assert {:ok, summary} = LLMUsageSummary.terminal(events)

    for rows <- [summary["llm_usage"], summary["llm_usage_by_model"]] do
      assert [
               %{
                 "calls" => 2,
                 "successful_calls" => 1,
                 "usage_calls" => 1,
                 "missing_usage_calls" => 1,
                 "usage" => usage
               }
             ] = rows

      assert usage == %{"input" => 6, "output" => 1}
      refute Map.has_key?(usage, "total_cost")
    end
  end

  test "an unmatched start with ambiguous model attribution keeps the alias row" do
    snapshot = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:writer/model")

    events = [
      event(1, "run-started", %{
        "missions" => %{},
        "connector_snapshots" => [snapshot, snapshot]
      }),
      llm_started_event(2, "capability-open"),
      event(3, "run-stopped", %{"outcome" => "timeout"})
    ]

    assert {:ok,
            %{
              "llm_usage" => [
                %{
                  "alias" => "writer",
                  "calls" => 1,
                  "successful_calls" => 0,
                  "usage_calls" => 0,
                  "missing_usage_calls" => 1
                }
              ],
              "llm_usage_by_model" => [],
              "unattributed_model_calls" => 1
            }} = LLMUsageSummary.terminal(events)
  end

  test "duplicate, reordered, mismatched, or dropped LLM events fail closed" do
    snapshot = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:writer/model")
    started = event(1, "run-started", %{"missions" => %{}, "connector_snapshots" => [snapshot]})
    stopped = event(4, "run-stopped", %{"outcome" => "ok"})

    invalid = [
      [
        started,
        llm_started_event(2, "capability-dup"),
        llm_started_event(3, "capability-dup"),
        stopped
      ],
      [
        started,
        llm_stopped_event(2, "capability-early", %{"input" => 1}),
        llm_started_event(3, "capability-early"),
        stopped
      ],
      [
        started,
        llm_started_event(2, "capability-mismatch"),
        llm_stopped_event(3, "capability-mismatch", %{"input" => 1}, %{"alias" => "other"}),
        stopped
      ],
      [
        started,
        llm_started_event(2, "capability-dup-stop"),
        llm_stopped_event(3, "capability-dup-stop", %{"input" => 1}),
        llm_stopped_event(4, "capability-dup-stop", %{"input" => 2}),
        event(5, "run-stopped", %{"outcome" => "ok"})
      ],
      [
        started,
        llm_started_event(2, "capability-open"),
        event(3, "events-dropped", %{"counts" => %{"capability-started" => 1}}),
        event(4, "run-stopped", %{"outcome" => "timeout"})
      ],
      [
        started,
        llm_started_event(2, "capability-open"),
        event(3, "events-dropped", %{"counts" => %{"capability-stopped" => 1}}),
        event(4, "run-stopped", %{"outcome" => "timeout"})
      ],
      [
        started,
        llm_started_event(2, "capability-open"),
        event(3, "events-dropped", %{"counts" => %{"$overflow" => 1}}),
        event(4, "run-stopped", %{"outcome" => "timeout"})
      ],
      [
        started,
        llm_started_event(2, "capability-name"),
        event(3, "capability-stopped", %{
          "environment" => "workflow",
          "name" => "http-request",
          "capability_id" => "capability-name",
          "status" => "error"
        }),
        stopped
      ],
      [
        started,
        llm_started_event(2, "capability-env"),
        llm_stopped_event(3, "capability-env", %{"input" => 1}, %{"environment" => "mission"}),
        stopped
      ],
      [
        started,
        llm_started_event(2, "capability-mission", %{"mission_name" => "alpha"}),
        llm_stopped_event(3, "capability-mission", %{"input" => 1}, %{"mission_name" => "beta"}),
        stopped
      ],
      [
        started,
        event(2, "capability-started", %{
          "environment" => "workflow",
          "name" => "http-request",
          "capability_id" => "capability-shared"
        }),
        llm_started_event(3, "capability-shared"),
        stopped
      ]
    ]

    for events <- invalid do
      assert {:error, :invalid_event_batch} = LLMUsageSummary.terminal(events)
    end
  end

  test "dropping unrelated event types leaves LLM accounting available" do
    snapshot = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:writer/model")

    events = [
      event(1, "run-started", %{"missions" => %{}, "connector_snapshots" => [snapshot]}),
      llm_started_event(2, "capability-ok"),
      llm_stopped_event(3, "capability-ok", %{"input" => 2}),
      event(4, "events-dropped", %{"counts" => %{"print" => 1}}),
      event(5, "run-stopped", %{"outcome" => "ok"})
    ]

    assert {:ok, %{"llm_usage" => [%{"calls" => 1, "usage_calls" => 1}]}} =
             LLMUsageSummary.terminal(events)
  end

  test "an unmatched LLM start next to a completed non-LLM capability stays available" do
    snapshot = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:writer/model")

    events = [
      event(1, "run-started", %{"missions" => %{}, "connector_snapshots" => [snapshot]}),
      event(2, "capability-started", %{
        "environment" => "workflow",
        "name" => "http-request",
        "capability_id" => "capability-http"
      }),
      event(3, "capability-stopped", %{
        "environment" => "workflow",
        "name" => "http-request",
        "capability_id" => "capability-http",
        "status" => "ok"
      }),
      llm_started_event(4, "capability-open"),
      event(5, "run-stopped", %{"outcome" => "timeout"})
    ]

    assert {:ok, %{"llm_usage" => [%{"calls" => 1, "missing_usage_calls" => 1}]}} =
             LLMUsageSummary.terminal(events)
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

  defp llm_started_event(sequence, capability_id, extra \\ %{}) do
    event(
      sequence,
      "capability-started",
      Map.merge(
        %{
          "environment" => "workflow",
          "name" => "llm-request",
          "capability_id" => capability_id,
          "alias" => "writer",
          "installation_revision" => "stable-v1"
        },
        extra
      )
    )
  end

  defp llm_stopped_event(sequence, capability_id, usage, extra \\ %{})
       when is_binary(capability_id) do
    data =
      Map.merge(
        %{
          "environment" => "workflow",
          "name" => "llm-request",
          "capability_id" => capability_id,
          "alias" => "writer",
          "installation_revision" => "stable-v1",
          "status" => "ok",
          "usage" => usage
        },
        extra
      )

    event(sequence, "capability-stopped", data)
  end

  defp llm_failed_event(sequence, capability_id, extra \\ %{}) do
    event(
      sequence,
      "capability-stopped",
      Map.merge(
        %{
          "environment" => "workflow",
          "name" => "llm-request",
          "capability_id" => capability_id,
          "alias" => "writer",
          "installation_revision" => "stable-v1",
          "status" => "error"
        },
        extra
      )
    )
  end
end
