defmodule PtcRunner.Kernel.RunAnalysisTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ConversationProjection
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.JSONSchema
  alias PtcRunner.Kernel.RunAnalysis
  alias PtcRunner.Kernel.RunAnalysisCapability
  alias PtcRunner.Kernel.RunAnalysisRelationships
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.TestSupport.PrivateInspectionFixture
  alias PtcRunner.TestSupport.StreamingInspection
  alias PtcRunner.TestSupport.TestHelpers

  @tag :tmp_dir
  test "run listing delegates the bounded native page", %{tmp_dir: root} do
    {:ok, trace} =
      TraceSnapshot.start({:directory, root},
        max_result_bytes: HostConfig.minimum_snapshot_result_bytes()
      )

    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace)

    assert {:ok, %{"items" => [], "snapshot_hash" => "sha256:" <> _}} =
             RunAnalysis.query(analysis, :runs, %{})

    assert {:error, :invalid_query} =
             RunAnalysis.query(analysis, :runs, %{"view" => "bogus"})
  end

  @tag :tmp_dir
  test "opens a run and reads its advertised primitive collections", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)

    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok, %{"items" => [%{"run_id" => run_id}]}} =
             RunAnalysis.query(analysis, :runs, %{})

    assert run_id == fixture.run_id

    bundle_hash = PrivateInspectionFixture.prelude_projection("component-#{run_id}")["hash"]

    assert {:ok, %{"items" => [%{"run_id" => ^run_id}]}} =
             RunAnalysis.query(analysis, :runs, %{"bundle" => bundle_hash})

    assert {:ok, %{"items" => []}} =
             RunAnalysis.query(analysis, :runs, %{"bundle" => "different-prelude"})

    assert {:ok,
            %{
              "run" => %{"run_id" => ^run_id, "complete" => true},
              "inspection" => %{"counts" => counts},
              "result" => %{"available?" => false},
              "collections" => collections
            }} = RunAnalysis.query(analysis, :open, %{"run_id" => run_id})

    assert counts["capability_calls"] == 1
    assert counts["provider_exchanges"] == 1
    assert counts["incomplete_model_exchanges"] == 0
    assert counts["incomplete_capability_calls"] == 0
    assert Enum.find(collections, &(&1["name"] == "activity"))["available?"]
    assert Enum.find(collections, &(&1["name"] == "turns"))["available?"]

    assert Enum.find(collections, &(&1["name"] == "activity")) ==
             %{
               "authority" => "public",
               "available?" => true,
               "filters" => ~w(status evaluation_id parent_evaluation_id capability mission_name),
               "identifier_locations" => %{
                 "evaluation_id" => "data.evaluation_id",
                 "parent_evaluation_id" => "data.parent_evaluation_id",
                 "sequence" => "sequence"
               },
               "name" => "activity",
               "order" => "sequence_asc",
               "sequence_domain" => "canonical_trace",
               "snapshot_domain" => "canonical_trace"
             }

    assert Enum.find(collections, &(&1["name"] == "model_exchanges"))[
             "item_completeness_field"
           ] == "complete?"

    assert Enum.find(collections, &(&1["name"] == "capability_calls"))[
             "item_completeness_field"
           ] == "complete?"

    refute Map.has_key?(
             Enum.find(collections, &(&1["name"] == "turns")),
             "item_completeness_field"
           )

    capability_id = "tool-#{run_id}"

    assert {:ok, %{"items" => [_ | _]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "activity"
             })

    assert {:ok,
            %{
              "evidence" => %{"complete?" => true},
              "items" => [
                %{
                  "generated" => [%{"source" => "(return 42)"}],
                  "feedback" => [],
                  "messages_added" => [%{"content" => prompt}],
                  "response" => %{"status" => "ok"}
                } = turn
              ]
            }} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "turns"
             })

    assert prompt == "private-prompt-#{run_id}"

    # The instructions that shaped the turn are the first thing a failed run is
    # opened for, and the conversation is the one view that certifies its own
    # completeness. It carries them.
    assert turn["system"] == "private-system-#{run_id}"

    assert {:ok, %{"items" => [%{"arguments" => %{"system" => "private-system-" <> ^run_id}}]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "model_exchanges"
             })

    assert {:ok, %{"items" => [%{"capability_id" => ^capability_id}]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "capability_calls"
             })

    assert {:ok, %{"items" => [%{"request_id" => 7, "request" => %{"method" => "tools/call"}}]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "provider_exchanges"
             })

    assert {:ok, %{"items" => [%{"kind" => "limit_exceeded"} = execution_error]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "execution_errors"
             })

    assert {:ok, %{"items" => [%{"value" => nil}]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "explicit_failure_values"
             })

    assert %{"filters" => nil, "state" => "incomplete"} =
             Enum.find(
               execution_error["relationships"],
               &(&1["rel"] == "direct_boundary_producer")
             )

    assert {:ok, %{"items" => [%{"source_hash" => "sha256:" <> _}]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "prelude_sources"
             })

    assert {:ok, %{"items" => [%{"source_hash" => "sha256:" <> _} = generated_source]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "generated_sources"
             })

    assert %{"state" => "incomplete"} =
             Enum.find(
               generated_source["relationships"],
               &(&1["rel"] == "referenced_prelude_source")
             )

    assert {:error, :invalid_query} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "activity",
               "limit" => 101
             })
  end

  @tag :tmp_dir
  test "follows a workflow error to its child source and producing turn", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root, "failure-navigation")
    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok, %{"collections" => collections}} =
             RunAnalysis.query(analysis, :open, %{"run_id" => fixture.run_id})

    assert "parent_evaluation_id" in Enum.find(collections, &(&1["name"] == "activity"))[
             "filters"
           ]

    assert "evaluation_id" in Enum.find(collections, &(&1["name"] == "turns"))["filters"]

    assert "parent_evaluation_id" in Enum.find(collections, &(&1["name"] == "turns"))["filters"]

    assert {:ok, %{"items" => [%{"evaluation_id" => workflow_evaluation_id}]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "execution_errors"
             })

    assert {:ok, %{"items" => child_activity}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "activity",
               "parent_evaluation_id" => workflow_evaluation_id
             })

    child_evaluation_ids =
      child_activity
      |> Enum.map(&get_in(&1, ["data", "evaluation_id"]))
      |> Enum.uniq()

    assert child_evaluation_ids == ["eval-#{fixture.run_id}"]
    [child_evaluation_id] = child_evaluation_ids

    assert {:ok,
            %{
              "items" => [
                %{
                  "evaluation_id" => ^child_evaluation_id,
                  "parent_evaluation_id" => ^workflow_evaluation_id,
                  "source" => "(return 42)"
                }
              ]
            }} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "generated_sources",
               "parent_evaluation_id" => workflow_evaluation_id
             })

    assert {:ok,
            %{
              "items" => [
                %{
                  "generated" => [
                    %{
                      "evaluation_id" => ^child_evaluation_id,
                      "parent_evaluation_id" => ^workflow_evaluation_id
                    }
                  ]
                }
              ]
            }} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "turns",
               "evaluation_id" => child_evaluation_id,
               "parent_evaluation_id" => workflow_evaluation_id
             })
  end

  @tag :tmp_dir
  test "typed relations follow a proven boundary producer to source, turn, and prelude", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create_boundary_failure!(root)
    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok, %{"items" => [error]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "execution_errors"
             })

    assert [boundary, children, producer, source_relation] = error["relationships"]
    assert boundary["rel"] == "boundary_failure"
    assert boundary["semantics"] == "causation"
    assert boundary["state"] == "complete"
    assert children["rel"] == "child_evaluations"
    assert children["semantics"] == "nesting"
    assert children["filters"] == %{"parent_evaluation_id" => error["evaluation_id"]}
    assert producer["rel"] == "direct_boundary_producer"

    assert producer["filters"] == %{
             "evaluation_id" => "eval-#{fixture.run_id}",
             "status" => "returned"
           }

    assert source_relation["target_collection"] == "generated_sources"

    assert {:ok, %{"items" => [%{"type" => "evaluation-stopped"}]}} =
             follow(analysis, fixture.run_id, producer)

    assert {:ok, %{"items" => [source]}} =
             follow(analysis, fixture.run_id, source_relation)

    assert [turn_relation, prelude_relation] = source["relationships"]
    assert turn_relation["rel"] == "producing_turn"
    assert turn_relation["state"] == "complete"
    assert prelude_relation["rel"] == "referenced_prelude_source"
    assert prelude_relation["state"] == "complete"

    assert {:ok, %{"items" => [%{"generated" => [_]}]}} =
             follow(analysis, fixture.run_id, turn_relation)

    assert {:ok, %{"items" => [%{"component_id" => "mission-component-" <> _}]}} =
             follow(analysis, fixture.run_id, prelude_relation)
  end

  test "typed relations keep ambiguous producer and turn candidates exact" do
    source = %{
      "run_id" => "run",
      "evaluation_id" => "eval",
      "environment" => "mission",
      "mission_name" => "default",
      "prelude_calls_available?" => true,
      "prelude_calls" => []
    }

    generated = Map.put(source, "association_ambiguous?", true)

    collections = %{
      turns: [%{"run_id" => "run", "generated" => [generated]}],
      turns_by_run_id: %{
        "run" => %{
          evidence: %{
            "complete?" => false,
            "canonical_complete?" => true,
            "missing_exchange_count" => 0,
            "ambiguity_count" => 1
          }
        }
      },
      effective_preludes: [],
      generated_sources: [source],
      execution_errors: [
        %{
          "run_id" => "run",
          "evaluation_id" => "workflow",
          "details" => %{
            "boundary_producer" => %{
              "complete?" => true,
              "evaluation_ids" => ["eval-a", "eval-b"]
            }
          }
        }
      ]
    }

    attached =
      RunAnalysisRelationships.attach(collections, %{
        "run" => %{
          "terminal?" => true,
          "events_dropped?" => false,
          "parent_evaluation_ids" => %{
            "eval-a" => "workflow",
            "eval-b" => "workflow"
          },
          "evaluation_statuses" => %{
            "workflow" => "error",
            "eval-a" => "returned",
            "eval-b" => "continued"
          }
        }
      })

    assert [%{"relationships" => [%{"state" => "ambiguous"}]}] =
             attached.generated_sources

    producer_relations =
      Enum.filter(
        hd(attached.execution_errors)["relationships"],
        &(&1["rel"] == "direct_boundary_producer")
      )

    assert Enum.map(producer_relations, & &1["filters"]["evaluation_id"]) == [
             "eval-a",
             "eval-b"
           ]

    assert Enum.all?(producer_relations, &(&1["state"] == "ambiguous"))

    source_relations =
      hd(attached.execution_errors)["relationships"]
      |> Enum.filter(&(&1["rel"] == "generated_source"))

    assert Enum.all?(source_relations, &(&1["state"] == "unavailable"))
    assert Enum.all?(source_relations, &is_nil(&1["filters"]))
  end

  test "typed causal relations reject a canonically successful workflow boundary" do
    collections = %{
      turns: [],
      turns_by_run_id: %{"run" => %{evidence: %{"complete?" => true}}},
      effective_preludes: [],
      generated_sources: [
        %{
          "run_id" => "run",
          "evaluation_id" => "mission-eval",
          "environment" => "mission",
          "mission_name" => "default",
          "prelude_calls_available?" => true,
          "prelude_calls" => []
        }
      ],
      execution_errors: [
        %{
          "run_id" => "run",
          "evaluation_id" => "workflow",
          "details" => %{
            "boundary_producer" => %{
              "complete?" => true,
              "evaluation_ids" => ["mission-eval"]
            }
          }
        }
      ]
    }

    attached =
      RunAnalysisRelationships.attach(collections, %{
        "run" => %{
          "terminal?" => true,
          "events_dropped?" => false,
          "parent_evaluation_ids" => %{"mission-eval" => "workflow"},
          "evaluation_statuses" => %{
            "workflow" => "ok",
            "mission-eval" => "returned"
          }
        }
      })

    relationships = hd(attached.execution_errors)["relationships"]

    for rel <- ["boundary_failure", "direct_boundary_producer", "generated_source"] do
      relation = Enum.find(relationships, &(&1["rel"] == rel))
      assert relation["state"] == "unavailable"
      assert relation["filters"] == nil
    end

    child_relation = Enum.find(relationships, &(&1["rel"] == "child_evaluations"))
    assert child_relation["state"] == "complete"
  end

  test "typed relations preserve explicitly incomplete producer evidence" do
    source = %{
      "run_id" => "run",
      "evaluation_id" => "mission-eval",
      "environment" => "mission",
      "mission_name" => "default",
      "prelude_calls_available?" => true,
      "prelude_calls" => []
    }

    collections = %{
      turns: [],
      turns_by_run_id: %{"run" => %{evidence: %{"complete?" => true}}},
      effective_preludes: [],
      generated_sources: [source],
      execution_errors: [
        %{
          "run_id" => "run",
          "evaluation_id" => "workflow",
          "details" => %{
            "boundary_producer" => %{
              "complete?" => false,
              "evaluation_ids" => ["mission-eval"]
            }
          }
        }
      ]
    }

    attached =
      RunAnalysisRelationships.attach(collections, %{
        "run" => %{
          "terminal?" => true,
          "events_dropped?" => false,
          "parent_evaluation_ids" => %{"mission-eval" => "workflow"},
          "evaluation_statuses" => %{
            "workflow" => "error",
            "mission-eval" => "returned"
          }
        }
      })

    relationships = hd(attached.execution_errors)["relationships"]
    producer = Enum.find(relationships, &(&1["rel"] == "direct_boundary_producer"))
    source_relation = Enum.find(relationships, &(&1["rel"] == "generated_source"))

    assert producer["state"] == "incomplete"
    assert producer["filters"] == %{"evaluation_id" => "mission-eval", "status" => "returned"}
    assert source_relation["state"] == "incomplete"
    assert source_relation["filters"] == %{"evaluation_id" => "mission-eval"}
  end

  test "prelude dependency relations qualify the exact occurrence of a repeated component" do
    collections =
      prelude_collections([
        prelude("workflow", nil, "shared"),
        prelude("mission", "reader", "base"),
        prelude("mission", "reader", "shared"),
        prelude("mission", "writer", "other"),
        prelude("mission", "writer", "shared")
      ])

    trace_facts = %{
      "run" => %{
        "workflow_prelude" => graph(["shared"], [[]]),
        "missions" => %{
          "reader" => %{"prelude" => graph(["base", "shared"], [[], [0]])},
          "writer" => %{"prelude" => graph(["other", "shared"], [[], [0]])}
        }
      }
    }

    attached = RunAnalysisRelationships.attach(collections, trace_facts)

    # `shared` occurs three times with three different dependency sets. A bare
    # component ID cannot distinguish them, so each edge must carry its
    # environment and mission name.
    assert dependency_relations(attached, "workflow", nil, "shared") == []

    assert dependency_relations(attached, "mission", "reader", "shared") == [
             %{
               "rel" => "dependency_prelude_source",
               "semantics" => "dependency",
               "target_collection" => "prelude_sources",
               "filters" => %{
                 "component_id" => "base",
                 "environment" => "mission",
                 "mission_name" => "reader"
               },
               "state" => "complete"
             }
           ]

    assert [%{"filters" => %{"component_id" => "other", "mission_name" => "writer"}}] =
             dependency_relations(attached, "mission", "writer", "shared")
  end

  test "prelude dependency relations report an unavailable occurrence rather than a bare id" do
    collections =
      prelude_collections([
        prelude("mission", "reader", "shared"),
        prelude("mission", "writer", "base")
      ])

    trace_facts = %{
      "run" => %{
        "missions" => %{
          "reader" => %{"prelude" => graph(["base", "shared"], [[], [0]])},
          "writer" => %{"prelude" => graph(["base"], [[]])}
        }
      }
    }

    attached = RunAnalysisRelationships.attach(collections, trace_facts)

    # `base` exists in the capture, but not as the reader occurrence the edge
    # names, so the state must not claim the writer's copy is followable here.
    assert [%{"state" => "unavailable"} = relation] =
             dependency_relations(attached, "mission", "reader", "shared")

    assert relation["filters"]["mission_name"] == "reader"
  end

  test "prelude dependency relations refuse a graph that breaks the positional contract" do
    malformed = [
      {"misaligned outer list", graph(["base", "shared"], [[]])},
      {"index out of bounds", graph(["base", "shared"], [[], [7]])},
      {"forward reference", graph(["base", "shared"], [[1], []])},
      {"self reference", graph(["base", "shared"], [[], [1]])},
      {"repeated index", graph(["base", "shared"], [[], [0, 0]])},
      {"descending indices", graph(["a", "b", "c"], [[], [0], [1, 0]])},
      {"repeated component id", graph(["shared", "shared"], [[], [0]])},
      {"non-integer index", graph(["base", "shared"], [[], ["0"]])},
      {"missing dependency_indices", %{"component_ids" => ["base", "shared"]}},
      {"absent graph", nil}
    ]

    for {label, prelude_graph} <- malformed do
      collections = prelude_collections([prelude("mission", "reader", "shared")])

      trace_facts = %{"run" => %{"missions" => %{"reader" => %{"prelude" => prelude_graph}}}}
      attached = RunAnalysisRelationships.attach(collections, trace_facts)

      assert [
               %{
                 "rel" => "dependency_prelude_source",
                 "filters" => nil,
                 "state" => "incomplete"
               }
             ] = dependency_relations(attached, "mission", "reader", "shared"),
             "expected #{label} to be reported as incomplete"
    end
  end

  test "prelude dependency relations stay exact at the accepted capture ceiling" do
    # A manifest may install 128 components per environment across 16 missions,
    # so the relationship pass must index occurrences rather than rescan the
    # run's preludes per edge. This also repeats every component ID in every
    # mission, which is the case a bare component ID cannot distinguish.
    missions = Enum.map(1..16, &"mission-#{&1}")
    component_ids = Enum.map(0..127, &"component.#{&1}")

    # Each component depends on its immediate predecessor: a 128-deep chain
    # that satisfies the strictly-earlier-position rule.
    dependency_indices = [[] | Enum.map(1..127, &[&1 - 1])]

    preludes =
      for mission <- missions, component_id <- component_ids do
        prelude("mission", mission, component_id)
      end

    collections = prelude_collections(preludes)

    trace_facts = %{
      "run" => %{
        "missions" =>
          Map.new(missions, fn mission ->
            {mission, %{"prelude" => graph(component_ids, dependency_indices)}}
          end)
      }
    }

    attached = RunAnalysisRelationships.attach(collections, trace_facts)
    assert length(attached.effective_preludes) == 16 * 128

    # Every edge resolves to its own mission's copy, never another mission's.
    for mission <- ["mission-1", "mission-9", "mission-16"] do
      assert dependency_relations(attached, "mission", mission, "component.0") == []

      assert [
               %{
                 "filters" => %{
                   "component_id" => "component.126",
                   "environment" => "mission",
                   "mission_name" => ^mission
                 },
                 "state" => "complete"
               }
             ] = dependency_relations(attached, "mission", mission, "component.127")
    end
  end

  test "generated entries embedded in turns carry the same relationships as generated_sources" do
    source = %{
      "run_id" => "run",
      "sequence" => 4,
      "evaluation_id" => "mission-eval",
      "environment" => "mission",
      "mission_name" => "default",
      "prelude_calls_available?" => true,
      "prelude_calls" => [%{"component_id" => "orders"}]
    }

    embedded =
      Map.merge(source, %{"association" => "source_match", "association_ambiguous?" => false})

    turn = %{"run_id" => "run", "stream_id" => "stream-1", "generated" => [embedded]}

    collections = %{
      turns: [turn],
      turns_by_run_id: %{"run" => %{items: [turn], evidence: %{"complete?" => true}}},
      effective_preludes: [prelude("mission", "default", "orders")],
      generated_sources: [source],
      execution_errors: []
    }

    attached =
      RunAnalysisRelationships.attach(collections, %{
        "run" => %{
          "missions" => %{"default" => %{"prelude" => graph(["orders"], [[]])}}
        }
      })

    expected = hd(attached.generated_sources)["relationships"]
    assert Enum.any?(expected, &(&1["rel"] == "referenced_prelude_source"))

    # A generic walker reading `turns` must be able to follow straight from the
    # embedded entry, without an extra exact `generated_sources` read.
    assert [%{"relationships" => ^expected} = entry] = hd(attached.turns)["generated"]
    assert entry["association"] == "source_match"

    assert [%{"relationships" => ^expected}] =
             hd(attached.turns_by_run_id["run"].items)["generated"]
  end

  test "typed relations do not trust an inspection producer without its canonical parent edge" do
    collections = %{
      turns: [],
      turns_by_run_id: %{"run" => %{evidence: %{"complete?" => true}}},
      effective_preludes: [],
      generated_sources: [],
      execution_errors: [
        %{
          "run_id" => "run",
          "evaluation_id" => "workflow",
          "details" => %{
            "boundary_producer" => %{
              "complete?" => true,
              "evaluation_ids" => ["unrelated-eval"]
            }
          }
        }
      ]
    }

    attached =
      RunAnalysisRelationships.attach(collections, %{
        "run" => %{
          "terminal?" => true,
          "events_dropped?" => false,
          "parent_evaluation_ids" => %{"unrelated-eval" => "other-workflow"},
          "evaluation_statuses" => %{
            "workflow" => "error",
            "unrelated-eval" => "returned"
          }
        }
      })

    relation =
      attached.execution_errors
      |> hd()
      |> Map.fetch!("relationships")
      |> Enum.find(&(&1["rel"] == "direct_boundary_producer"))

    assert relation["state"] == "unavailable"
    assert relation["filters"] == nil
  end

  test "conversation streams choose the unique longest complete prefix" do
    user = %{"role" => "user", "content" => "start"}
    assistant_1 = %{"role" => "assistant", "content" => nil, "tool_calls" => [%{"id" => "1"}]}
    feedback_1 = %{"role" => "tool", "tool_call_id" => "1", "content" => "first"}
    assistant_2 = %{"role" => "assistant", "content" => nil, "tool_calls" => [%{"id" => "2"}]}
    feedback_2 = %{"role" => "tool", "tool_call_id" => "2", "content" => "second"}

    exchanges = [
      exchange(1, [user], assistant_1),
      exchange(3, [user, assistant_1, feedback_1], assistant_2),
      exchange(5, [user, assistant_1, feedback_1, assistant_2, feedback_2], %{
        "role" => "assistant",
        "content" => "done"
      })
    ]

    assert %{"ambiguous?" => false, "streams" => [%{"turns" => turns}]} =
             ConversationProjection.streams(exchanges)

    assert Enum.map(turns, & &1["turn"]) == [1, 2, 3]
    assert Enum.at(turns, 1)["messages_added"] == [feedback_1]
    assert Enum.at(turns, 1)["feedback"] == [feedback_1]
    assert Enum.at(turns, 2)["messages_added"] == [feedback_2]
    assert Enum.at(turns, 2)["feedback"] == [feedback_2]
  end

  test "conversation streams equate absent tool-call narration across captures" do
    user = %{"role" => "user", "content" => "start"}
    call = %{"id" => "1", "name" => "run_ptc_lisp", "args" => %{"program" => "42"}}
    carried = %{"role" => "assistant", "content" => nil, "tool_calls" => [call]}
    feedback = %{"role" => "tool", "tool_call_id" => "1", "content" => "42"}

    for content_fields <- [%{"content" => ""}, %{"content" => " \n\t"}, %{}] do
      captured =
        %{"role" => "assistant", "tool_calls" => [call]}
        |> Map.merge(content_fields)

      exchanges = [
        exchange(1, [user], captured),
        exchange(3, [user, carried, feedback], %{"role" => "assistant", "content" => "done"})
      ]

      assert %{"ambiguous?" => false, "streams" => [%{"turns" => turns}]} =
               ConversationProjection.streams(exchanges)

      assert Enum.map(turns, & &1["turn"]) == [1, 2]
      assert hd(turns)["assistant"] == captured
    end
  end

  test "conversation stream matching keeps other message content exact" do
    user = %{"role" => "user", "content" => "start"}
    call = %{"id" => "1", "name" => "run_ptc_lisp", "args" => %{"program" => "42"}}
    feedback = %{"role" => "tool", "tool_call_id" => "1", "content" => "42"}

    narrated = %{"role" => "assistant", "content" => "I will inspect.", "tool_calls" => [call]}
    narration_dropped = %{"role" => "assistant", "content" => nil, "tool_calls" => [call]}

    assert %{"streams" => [%{"turns" => [_]}, %{"turns" => [_]}]} =
             ConversationProjection.streams([
               exchange(1, [user], narrated),
               exchange(3, [user, narration_dropped, feedback], narrated)
             ])

    blank_user = %{"role" => "user", "content" => ""}
    nil_user = %{"role" => "user", "content" => nil}
    assistant = %{"role" => "assistant", "content" => nil, "tool_calls" => [call]}

    assert %{"streams" => [%{"turns" => [_]}, %{"turns" => [_]}]} =
             ConversationProjection.streams([
               exchange(1, [blank_user], assistant),
               exchange(3, [nil_user, assistant, feedback], assistant)
             ])
  end

  test "conversation streams preserve equal maximal forks as ambiguous" do
    user = %{"role" => "user", "content" => "same"}
    assistant = %{"role" => "assistant", "content" => "same answer"}

    exchanges = [
      exchange(1, [user], assistant, "a"),
      exchange(3, [user], assistant, "b"),
      exchange(5, [user, assistant, %{"role" => "user", "content" => "next"}], assistant, "c")
    ]

    assert %{"ambiguous?" => true, "ambiguous" => [%{"capability_id" => "c"}]} =
             ConversationProjection.streams(exchanges)
  end

  test "turn projection labels duplicate source matches without inventing an exact edge" do
    assistant = %{
      "role" => "assistant",
      "tool_calls" => [%{"args" => %{"program" => "(return 42)"}}]
    }

    programs = [
      %{"evaluation_id" => "evaluation-1", "source" => "(return 42)"},
      %{"evaluation_id" => "evaluation-2", "source" => "(return 42)"}
    ]

    projection =
      ConversationProjection.compile(
        [exchange(1, [%{"role" => "user", "content" => "run it"}], assistant)],
        programs,
        %{"terminal?" => true, "events_dropped?" => false}
      )

    assert [turn] = projection.items
    assert Enum.map(turn["generated"], & &1["association"]) == ["source_match", "source_match"]
    assert Enum.all?(turn["generated"], & &1["association_ambiguous?"])
    refute projection.evidence["complete?"]
    assert projection.evidence["ambiguity_count"] == 1
  end

  @tag :tmp_dir
  test "rejects an inspection snapshot captured against another trace snapshot", %{tmp_dir: root} do
    left = PrivateInspectionFixture.create!(Path.join(root, "left"), "left")
    right = PrivateInspectionFixture.create!(Path.join(root, "right"), "right")
    {:ok, left_trace} = TraceSnapshot.start({:private_authorized_directory, left.traces})
    {:ok, right_trace} = TraceSnapshot.start({:private_authorized_directory, right.traces})

    {:ok, right_inspection} =
      InspectionSnapshot.start({:directory, right.inspection}, right_trace)

    on_exit(fn -> InspectionSnapshot.stop(right_inspection) end)
    on_exit(fn -> TraceSnapshot.stop(right_trace) end)
    on_exit(fn -> TraceSnapshot.stop(left_trace) end)

    assert {:error, :invalid_run_analysis} = RunAnalysis.new(left_trace, right_inspection)
  end

  @tag :tmp_dir
  test "keeps canonical answers available when a private catalog has no artifact for the run", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root, "with-inspection")
    trace_only = "trace-only"

    File.write!(
      Path.join(fixture.traces, "#{trace_only}.jsonl"),
      Enum.map_join(PrivateInspectionFixture.canonical_events(trace_only), "", fn event ->
        Jason.encode!(event) <> "\n"
      end)
    )

    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok,
            %{
              "run" => %{"run_id" => ^trace_only},
              "inspection" => %{"available?" => false},
              "result" => %{"available?" => false},
              "collections" => collections
            }} = RunAnalysis.query(analysis, :open, %{"run_id" => trace_only})

    assert Enum.find(collections, &(&1["name"] == "activity"))["available?"]
    refute Enum.find(collections, &(&1["name"] == "turns"))["available?"]

    assert {:ok, %{"items" => [_ | _]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => trace_only,
               "collection" => "activity"
             })

    assert {:error, :evidence_unavailable} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => trace_only,
               "collection" => "turns"
             })

    assert {:error, :not_found} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => "unknown",
               "collection" => "turns"
             })

    assert {:error, :not_found} =
             RunAnalysis.query(analysis, :open, %{"run_id" => "unknown"})
  end

  @tag :tmp_dir
  test "conversation completeness reconciles private exchanges with canonical evidence", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root, "missing-exchange")
    remove_capability_records!(fixture.inspection, "llm-#{fixture.run_id}")
    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok,
            %{
              "evidence" => %{
                "canonical_complete?" => true,
                "complete?" => false,
                "missing_exchange_count" => 1
              },
              "items" => []
            }} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "turns"
             })
  end

  @tag :tmp_dir
  test "conversation completeness requires a canonical terminal event", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root, "open-run")
    trace_path = Path.join(fixture.traces, "#{fixture.run_id}.jsonl")

    trace_path
    |> File.stream!()
    |> Enum.reject(fn line -> line |> Jason.decode!() |> Map.fetch!("type") == "run-stopped" end)
    |> then(&File.write!(trace_path, &1))

    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok, %{"evidence" => %{"canonical_complete?" => false, "complete?" => false}}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "turns"
             })
  end

  @tag :tmp_dir
  test "read returns primitive cursors for the caller to follow", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok,
            %{
              "items" => [_event],
              "next_cursor" => cursor,
              "truncated" => true
            }} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "activity",
               "limit" => 1
             })

    assert {:ok, %{"items" => [_event], "snapshot_hash" => snapshot_hash}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "activity",
               "limit" => 1,
               "cursor" => cursor
             })

    assert is_binary(snapshot_hash)
  end

  @tag :tmp_dir
  test "internal collection rejects a multi-page aggregate above the result-byte limit", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root)
    max_result_bytes = 5_000

    {:ok, trace} =
      TraceSnapshot.start({:private_authorized_directory, fixture.traces},
        max_result_bytes: max_result_bytes
      )

    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace)

    assert {:ok, %{"next_cursor" => cursor}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "activity",
               "limit" => 100
             })

    assert is_binary(cursor)

    assert {:error, :result_limit_exceeded} =
             RunAnalysis.collect(analysis, fixture.run_id, "activity", 100)
  end

  @tag :tmp_dir
  test "read does not require an oversized run summary", %{tmp_dir: root} do
    run_id = "large-summary"

    [started | events] = PrivateInspectionFixture.canonical_events(run_id)

    started =
      put_in(started, ["data", "missions"], %{
        "large" => %{"private_metadata" => String.duplicate("x", 20_000)}
      })

    File.write!(
      Path.join(root, "#{run_id}.jsonl"),
      Enum.map_join([started | events], "", &(Jason.encode!(&1) <> "\n"))
    )

    {:ok, trace} =
      TraceSnapshot.start({:private_authorized_directory, root}, max_result_bytes: 5_000)

    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace)

    assert {:error, :result_limit_exceeded} =
             TraceSnapshot.query(trace, :get_run, %{"run_id" => run_id})

    assert {:ok, %{"items" => [%{"data" => %{"name" => "llm-request"}}]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "activity",
               "capability" => "llm-request",
               "limit" => 1
             })
  end

  @tag :tmp_dir
  test "read does not compose independently bounded private collections", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, sizing_trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})

    {:ok, sizing_inspection} =
      InspectionSnapshot.start({:directory, fixture.inspection}, sizing_trace)

    {:ok, exchanges} =
      InspectionSnapshot.query(sizing_inspection, :model_exchanges, %{
        "run_id" => fixture.run_id,
        "limit" => 1_000
      })

    {:ok, programs} =
      InspectionSnapshot.query(sizing_inspection, :generated_sources, %{
        "run_id" => fixture.run_id,
        "limit" => 1_000
      })

    assert {:ok, analysis} = RunAnalysis.new(sizing_trace, sizing_inspection)

    assert {:ok, ^exchanges} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "model_exchanges",
               "limit" => 100
             })

    assert {:ok, ^programs} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "generated_sources",
               "limit" => 100
             })

    :ok = InspectionSnapshot.stop(sizing_inspection)
    :ok = TraceSnapshot.stop(sizing_trace)
  end

  @tag :tmp_dir
  test "one capability builder exposes runs, open, read, then counters", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)

    assert RunAnalysis.operations() == [:runs, :open, :read, :counters]
    assert {:ok, capabilities} = RunAnalysisCapability.from_snapshots(trace, inspection)

    assert Enum.map(capabilities, & &1.name) == [
             "analysis-runs",
             "analysis-open",
             "analysis-read",
             "analysis-counters"
           ]

    runs = Enum.find(capabilities, &(&1.name == "analysis-runs"))
    read = Enum.find(capabilities, &(&1.name == "analysis-read"))
    counters = Enum.find(capabilities, &(&1.name == "analysis-counters"))
    assert runs.input_schema["properties"]["bundle"]["type"] == "string"
    assert read.input_schema["properties"]["limit"]["maximum"] == 100
    assert read.input_schema["properties"]["parent_evaluation_id"]["type"] == "string"
    assert counters.input_schema["additionalProperties"] == false
    assert counters.input_schema["required"] == []
    assert counters.input_schema["properties"]["tags"]["maxProperties"] == 16

    assert counters.input_schema["properties"]["tags"]["propertyNames"] == %{
             "type" => "string",
             "maxLength" => 256
           }

    assert {:ok, %{"items" => [_]}} =
             read.callback.(%{"run_id" => fixture.run_id, "collection" => "turns"})

    assert {:ok, provider_capabilities} =
             RunAnalysisCapability.from_snapshots(trace, inspection, "evidence")

    assert Enum.map(provider_capabilities, & &1.name) == [
             "evidence.runs",
             "evidence.open",
             "evidence.read",
             "evidence.counters"
           ]

    alias_119 = "a" <> String.duplicate("b", 118)
    alias_120 = "a" <> String.duplicate("b", 119)
    assert byte_size(alias_119) == 119
    assert byte_size(alias_120) == 120

    assert {:ok, long_capabilities} =
             RunAnalysisCapability.from_snapshots(trace, inspection, alias_119)

    assert Enum.map(long_capabilities, & &1.name) == [
             alias_119 <> ".runs",
             alias_119 <> ".open",
             alias_119 <> ".read",
             alias_119 <> ".counters"
           ]

    assert {:error, :invalid_run_analysis_capability} =
             RunAnalysisCapability.from_snapshots(trace, inspection, alias_120)
  end

  @tag :tmp_dir
  test "counters delegates the captured snapshot aggregate unchanged", %{tmp_dir: root} do
    write_counter_runs!(root)

    {:ok, trace} = TraceSnapshot.start({:directory, root}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace)

    empty = %{}
    assert {:ok, expected} = TraceSnapshot.query(trace, :counters, empty)
    assert {:ok, ^expected} = RunAnalysis.query(analysis, :counters, empty)

    filters = [
      %{"status" => "ok"},
      %{"run_id" => "second"},
      %{"trace_id" => "trace-second"},
      %{"tags" => %{"cohort" => "candidate"}},
      %{"name" => "second-run"},
      %{"bundle" => "missing-bundle"},
      %{"model" => "openrouter:vendor/model-b"},
      %{"provider" => "openrouter"},
      %{"from" => "2026-01-01T00:00:00Z"},
      %{"to" => "2027-01-01T00:00:00Z"},
      %{"mission_name" => "default"}
    ]

    for arguments <- filters do
      assert {:ok, expected_page} = TraceSnapshot.query(trace, :counters, arguments)
      assert {:ok, ^expected_page} = RunAnalysis.query(analysis, :counters, arguments)
    end

    assert {:ok, %{"llm_usage_by_model" => [%{"resolved_model" => resolved}]}} =
             RunAnalysis.query(analysis, :counters, %{"run_id" => "second"})

    assert resolved == "openrouter:vendor/model-b"

    assert {:ok, %{"unattributed_model_calls" => 1, "llm_usage" => usage}} =
             RunAnalysis.query(analysis, :counters, %{})

    assert Enum.any?(usage, &(&1["alias"] == "writer"))
    assert Enum.any?(usage, &(&1["installation_revision"] == "review-v2"))

    File.write!(
      Path.join(root, "later.jsonl"),
      Jason.encode!(counter_event("later", 1, "run-started", %{"missions" => %{}})) <> "\n"
    )

    assert {:ok, ^expected} = RunAnalysis.query(analysis, :counters, empty)
  end

  @tag :tmp_dir
  test "counter filters fail closed at schema then at the canonical query", %{tmp_dir: root} do
    write_counter_runs!(root)
    {:ok, trace} = TraceSnapshot.start({:directory, root}, owner: self())
    on_exit(fn -> TraceSnapshot.stop(trace) end)

    assert {:ok, capabilities} = RunAnalysisCapability.from_snapshots(trace)
    counters = Enum.find(capabilities, &(&1.name == "analysis-counters"))
    properties = Map.keys(counters.input_schema["properties"]) |> Enum.sort()

    assert properties ==
             ~w(bundle from mission_name model name provider run_id status tags to trace_id)

    ascii_limit = String.duplicate("a", 256)
    ascii_overflow = String.duplicate("a", 257)
    utf8_overflow = String.duplicate("é", 129)
    sixteen_tags = Map.new(1..16, &{"tag-#{&1}", "value-#{&1}"})
    seventeen_tags = Map.put(sixteen_tags, "tag-17", "extra")
    ascii_key = String.duplicate("k", 256)
    overflow_key = String.duplicate("k", 257)

    assert JSONSchema.valid?(counters.input_validator, %{})
    assert JSONSchema.valid?(counters.input_validator, %{"run_id" => ascii_limit})
    assert JSONSchema.valid?(counters.input_validator, %{"tags" => sixteen_tags})
    assert JSONSchema.valid?(counters.input_validator, %{"tags" => %{ascii_key => "ok"}})
    assert JSONSchema.valid?(counters.input_validator, %{"name" => utf8_overflow})
    assert JSONSchema.valid?(counters.input_validator, %{"tags" => %{utf8_overflow => "ok"}})
    refute JSONSchema.valid?(counters.input_validator, %{"tags" => seventeen_tags})
    refute JSONSchema.valid?(counters.input_validator, %{"tags" => %{overflow_key => "ok"}})
    refute JSONSchema.valid?(counters.input_validator, %{"run_id" => ascii_overflow})
    refute JSONSchema.valid?(counters.input_validator, %{"limit" => 1})
    refute JSONSchema.valid?(counters.input_validator, %{"cursor" => "next"})
    refute JSONSchema.valid?(counters.input_validator, %{"view" => "full"})
    refute JSONSchema.valid?(counters.input_validator, %{"run_ids" => ["second"]})
    refute JSONSchema.valid?(counters.input_validator, %{"unsupported" => true})

    assert {:ok, analysis} = RunAnalysis.new(trace)
    assert {:ok, %{"runs" => 0}} = counters.callback.(%{"tags" => sixteen_tags})

    assert {:error, %{kind: :invalid_request, details: "invalid analysis query"}} =
             counters.callback.(%{"name" => utf8_overflow})

    assert {:error, %{kind: :invalid_request, details: "invalid analysis query"}} =
             counters.callback.(%{"tags" => %{utf8_overflow => "ok"}})

    assert {:error, %{kind: :invalid_request, details: "invalid analysis query"}} =
             counters.callback.(%{"from" => "not-a-timestamp"})

    assert {:error, :invalid_query} =
             RunAnalysis.query(analysis, :counters, %{"view" => "full"})
  end

  @tag :tmp_dir
  test "an oversized counter aggregate fails closed without a partial map", %{tmp_dir: root} do
    write_counter_runs!(root)

    {:ok, trace} =
      TraceSnapshot.start({:directory, root}, owner: self(), max_result_bytes: 100)

    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace)

    assert {:error, :result_limit_exceeded} = TraceSnapshot.query(trace, :counters, %{})
    assert {:error, :result_limit_exceeded} = RunAnalysis.query(analysis, :counters, %{})

    assert {:ok, capabilities} = RunAnalysisCapability.from_snapshots(trace)
    counters = Enum.find(capabilities, &(&1.name == "analysis-counters"))

    assert {:error, %{kind: :invalid_request, details: "analysis result limit exceeded"}} =
             counters.callback.(%{})
  end

  defp write_counter_runs!(directory) do
    first = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:vendor/model-a")
    second = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:vendor/model-b")
    reviewer = TestHelpers.llm_snapshot("reviewer", "review-v2", "openrouter:vendor/model-a")

    runs = [
      {"first",
       counter_run("first", first, "ok", %{"input" => 3, "output" => 2, "total_cost" => 0.25})},
      {"second", counter_run("second", second, "ok", %{"input" => 5})},
      {"review", counter_run("review", reviewer, "ok", %{"input" => 7}, "reviewer", "review-v2")},
      {"private", counter_run("private", nil, "error", nil)}
    ]

    Enum.each(runs, fn {run_id, events} ->
      encoded = Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))
      File.write!(Path.join(directory, "#{run_id}.jsonl"), encoded)
    end)
  end

  defp counter_run(
         run_id,
         snapshot_or_snapshots,
         status,
         usage,
         alias_name \\ "writer",
         revision \\ "stable-v1"
       ) do
    snapshots =
      case snapshot_or_snapshots do
        nil -> []
        snapshots when is_list(snapshots) -> snapshots
        snapshot -> [snapshot]
      end

    labels = %{
      "name" => run_id <> "-run",
      "provider" => "openrouter",
      "tags" => %{"cohort" => "candidate"}
    }

    labels =
      case snapshot_or_snapshots do
        %{"acquisition" => %{"resolved_model" => model}} -> Map.put(labels, "model", model)
        _other -> labels
      end

    started = %{
      "missions" => %{},
      "connector_snapshots" => snapshots,
      "labels" => labels
    }

    stopped = %{
      "environment" => "workflow",
      "name" => "llm-request",
      "alias" => alias_name,
      "installation_revision" => revision,
      "status" => status
    }

    stopped = if is_nil(usage), do: stopped, else: Map.put(stopped, "usage", usage)

    [
      counter_event(run_id, 1, "run-started", started),
      counter_event(run_id, 2, "capability-stopped", stopped),
      counter_event(run_id, 3, "run-stopped", %{"outcome" => "ok"})
    ]
  end

  defp counter_event(run_id, sequence, type, data) do
    %{
      "schema_version" => 2,
      "run_id" => run_id,
      "trace_id" => "trace-#{run_id}",
      "sequence" => sequence,
      "timestamp" => "2026-07-12T12:00:00Z",
      "type" => type,
      "data" => data
    }
  end

  defp exchange(sequence, messages, assistant, id \\ nil) do
    %{
      "capability_id" => id || "cap-#{sequence}",
      "input_sequence" => sequence,
      "output_sequence" => sequence + 1,
      "arguments" => %{"messages" => messages, "system" => "system"},
      "result" => %{"status" => "ok", "value" => Map.delete(assistant, "role")}
    }
  end

  defp prelude_collections(preludes) do
    %{
      turns: [],
      turns_by_run_id: %{"run" => %{items: [], evidence: %{"complete?" => true}}},
      effective_preludes: preludes,
      generated_sources: [],
      execution_errors: []
    }
  end

  defp prelude(environment, mission_name, component_id) do
    %{
      "run_id" => "run",
      "environment" => environment,
      "mission_name" => mission_name,
      "component_id" => component_id
    }
  end

  defp graph(component_ids, dependency_indices),
    do: %{"component_ids" => component_ids, "dependency_indices" => dependency_indices}

  defp dependency_relations(attached, environment, mission_name, component_id) do
    attached.effective_preludes
    |> Enum.find(
      &(&1["environment"] == environment and &1["mission_name"] == mission_name and
          &1["component_id"] == component_id)
    )
    |> Map.fetch!("relationships")
  end

  defp follow(analysis, run_id, relationship) do
    arguments =
      relationship["filters"]
      |> Map.put("run_id", run_id)
      |> Map.put("collection", relationship["target_collection"])

    RunAnalysis.query(analysis, :read, arguments)
  end

  defp remove_capability_records!(directory, capability_id) do
    [path] = Path.wildcard(Path.join(directory, "*.ptcins"))

    {:ok, records} = StreamingInspection.read_path(path)

    retained =
      records
      |> Enum.reject(fn record ->
        get_in(record, ["correlation", "capability_id"]) == capability_id
      end)

    StreamingInspection.rewrite_path(path, retained)
  end
end
