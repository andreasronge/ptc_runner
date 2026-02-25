defmodule Alma.DebugLogTest do
  use ExUnit.Case, async: true

  alias Alma.DebugLog

  describe "format_parents/2" do
    test "formats design with runtime_logs containing tool calls" do
      parent = %{
        design: %{name: "spatial_v1"},
        score: 0.35,
        trajectories: [
          %{
            success?: true,
            steps: 3,
            runtime_logs: [
              %{
                phase: :recall,
                prints: ["looking up flask"],
                tool_calls: [
                  %{
                    name: "find-similar",
                    args: %{"query" => "flask", "k" => 3},
                    result: [%{"text" => "flask in room_B"}]
                  }
                ]
              },
              %{
                phase: :"mem-update",
                prints: ["storing observations"],
                tool_calls: [
                  %{name: "store-obs", args: %{"text" => "visited room_A"}, result: "stored:1"}
                ]
              }
            ]
          }
        ]
      }

      output = DebugLog.format_parents([parent])

      assert output =~ "=== DESIGN: spatial_v1 (score: 0.35) ==="
      assert output =~ "--- EPISODE D1: SUCCESS (3 steps) ---"
      assert output =~ "[D1:recall] PRINT: looking up flask"
      assert output =~ "[D1:recall] TOOL find-similar:"
      assert output =~ "[D1:mem-update] PRINT: storing observations"
      assert output =~ "[D1:mem-update] TOOL store-obs:"
      assert output =~ "stored:1"
    end

    test "gracefully handles entries without runtime_logs" do
      parent = %{
        design: %{name: "old_design"},
        score: 0.5,
        trajectories: [
          %{success?: false, steps: 20}
        ]
      }

      output = DebugLog.format_parents([parent])

      assert output =~ "=== DESIGN: old_design (score: 0.5) ==="
      assert output =~ "--- EPISODE D1: FAILED (20 steps) ---"
      refute output =~ "TOOL"
      refute output =~ "PRINT"
    end

    test "includes runtime errors in log output" do
      parent = %{
        design: %{name: "broken_v1"},
        score: 0.0,
        trajectories: [
          %{
            success?: false,
            steps: 1,
            runtime_logs: [
              %{
                phase: :"mem-update",
                prints: ["about to crash"],
                tool_calls: [],
                error: "type_error: add: invalid argument types"
              }
            ]
          }
        ]
      }

      output = DebugLog.format_parents([parent])

      assert output =~ "[D1:mem-update] ERROR: type_error: add: invalid argument types"
      assert output =~ "[D1:mem-update] PRINT: about to crash"
    end

    test "includes task-level errors" do
      parent = %{
        design: %{name: "timeout_v1"},
        score: 0.0,
        trajectories: [
          %{
            success?: false,
            steps: 0,
            error: "task crashed: timeout",
            runtime_logs: []
          }
        ]
      }

      output = DebugLog.format_parents([parent])

      assert output =~ "[D1:task] ERROR: task crashed: timeout"
    end

    test "includes recall RETURN value" do
      parent = %{
        design: %{name: "return_test"},
        score: 0.5,
        trajectories: [
          %{
            success?: true,
            steps: 3,
            runtime_logs: [
              %{
                phase: :recall,
                prints: [],
                tool_calls: [],
                return: "flask is in room_B, go east",
                error: nil
              }
            ]
          }
        ]
      }

      output = DebugLog.format_parents([parent])

      assert output =~ "[D1:recall] RETURN:"
      assert output =~ "flask is in room_B"
    end

    test "includes task agent actions from observation_log" do
      parent = %{
        design: %{name: "actions_test"},
        score: 0.5,
        trajectories: [
          %{
            success?: true,
            steps: 3,
            runtime_logs: [],
            observation_log: [
              %{action: "look", result: %{message: "You are in room_A. Exits: room_B"}},
              %{action: "move_to", result: %{message: "Moved to room_B"}},
              %{action: "pick_up", result: %{message: "Picked up flask"}}
            ]
          }
        ]
      }

      output = DebugLog.format_parents([parent])

      assert output =~ "[D1:task] look: You are in room_A"
      assert output =~ "[D1:task] move_to: Moved to room_B"
      assert output =~ "[D1:task] pick_up: Picked up flask"
    end

    test "truncates long tool results" do
      long_result = String.duplicate("x", 500)

      parent = %{
        design: %{name: "test"},
        score: 0.1,
        trajectories: [
          %{
            success?: true,
            steps: 1,
            runtime_logs: [
              %{
                phase: :recall,
                prints: [],
                tool_calls: [
                  %{name: "find-similar", args: %{"query" => "test"}, result: long_result}
                ]
              }
            ]
          }
        ]
      }

      output = DebugLog.format_parents([parent], max_result_chars: 50)
      # The long result should be truncated
      assert String.length(output) < String.length(long_result)
      assert output =~ "..."
    end

    test "formats multiple designs" do
      parents = [
        %{design: %{name: "design_a"}, score: 0.8, trajectories: []},
        %{design: %{name: "design_b"}, score: 0.2, trajectories: []}
      ]

      output = DebugLog.format_parents(parents)

      assert output =~ "design_a (score: 0.8)"
      assert output =~ "design_b (score: 0.2)"
    end

    test "includes collection trajectories with mem-update tool calls" do
      parent = %{
        design: %{name: "with_collection"},
        score: 0.4,
        collection_trajectories: [
          %{
            success?: true,
            steps: 5,
            runtime_logs: [
              %{
                phase: :recall,
                prints: [],
                tool_calls: [
                  %{
                    name: "find-similar",
                    args: %{"query" => "torch"},
                    result: []
                  }
                ]
              },
              %{
                phase: :"mem-update",
                prints: [],
                tool_calls: [
                  %{
                    name: "store-obs",
                    args: %{"text" => "torch at room_B", "collection" => "objects"},
                    result: "stored:1"
                  },
                  %{
                    name: "graph-update",
                    args: %{"edges" => [["room_A", "room_B"]]},
                    result: "ok"
                  }
                ]
              }
            ]
          }
        ],
        trajectories: [
          %{
            success?: true,
            steps: 3,
            runtime_logs: [
              %{phase: :recall, prints: [], tool_calls: []}
            ]
          }
        ]
      }

      output = DebugLog.format_parents([parent])

      assert output =~ "--- COLLECTION PHASE ---"
      assert output =~ "--- DEPLOYMENT PHASE ---"
      assert output =~ "[C1:mem-update] TOOL store-obs:"
      assert output =~ "stored:1"
      assert output =~ "[C1:mem-update] TOOL graph-update:"
    end

    test "works without collection_trajectories key" do
      parent = %{
        design: %{name: "legacy"},
        score: 0.3,
        trajectories: [
          %{success?: true, steps: 2, runtime_logs: []}
        ]
      }

      output = DebugLog.format_parents([parent])

      assert output =~ "legacy"
      assert output =~ "--- DEPLOYMENT PHASE ---"
      refute output =~ "--- COLLECTION PHASE ---"
    end
  end

  describe "similarity stats formatting" do
    test "formats per-query similarity lines in runtime log" do
      parent = %{
        design: %{name: "embed_test"},
        score: 0.5,
        trajectories: [
          %{
            success?: true,
            steps: 3,
            runtime_logs: [
              %{
                phase: :recall,
                prints: [],
                tool_calls: [],
                similarity_stats: [
                  %{op: :find, query: "find the key", scores: [0.92, 0.45, 0.12], embed_ms: 42}
                ],
                embed_mode: :dense
              }
            ]
          }
        ]
      }

      output = DebugLog.format_parents([parent])

      assert output =~ "[D1:recall] SIMILARITY: query=\"find the key\""
      assert output =~ "top=0.920"
      assert output =~ "spread=0.800"
      assert output =~ "embed_ms=42"
      assert output =~ "OK"
      assert output =~ "[D1:recall] SIM_SUMMARY: 1 queries"
      assert output =~ "embed=dense"
    end

    test "flags low quality scores" do
      parent = %{
        design: %{name: "ngram_test"},
        score: 0.1,
        trajectories: [
          %{
            success?: false,
            steps: 20,
            runtime_logs: [
              %{
                phase: :recall,
                prints: [],
                tool_calls: [],
                similarity_stats: [
                  %{op: :find, query: "key", scores: [0.22, 0.19, 0.17], embed_ms: 0}
                ],
                embed_mode: :ngram
              }
            ]
          }
        ]
      }

      output = DebugLog.format_parents([parent])

      assert output =~ "LOW_QUALITY"
      assert output =~ "low_quality=1"
      assert output =~ "embed=ngram"
    end

    test "formats aggregate similarity section across episodes" do
      parent = %{
        design: %{name: "agg_test"},
        score: 0.6,
        trajectories: [
          %{
            success?: true,
            steps: 3,
            runtime_logs: [
              %{
                phase: :recall,
                prints: [],
                tool_calls: [],
                similarity_stats: [
                  %{op: :find, query: "key", scores: [0.95, 0.3], embed_ms: 40}
                ],
                embed_mode: :dense
              }
            ]
          },
          %{
            success?: true,
            steps: 5,
            runtime_logs: [
              %{
                phase: :recall,
                prints: [],
                tool_calls: [],
                similarity_stats: [
                  %{op: :find, query: "torch", scores: [0.4, 0.2], embed_ms: 35}
                ],
                embed_mode: :dense
              }
            ]
          }
        ]
      }

      output = DebugLog.format_parents([parent])

      assert output =~ "=== SIMILARITY QUALITY ==="
      assert output =~ "Embed mode: dense"
      assert output =~ "Total queries: 2"
      assert output =~ "Low quality (top < 0.5): 1/2"
    end

    test "handles empty similarity stats gracefully" do
      parent = %{
        design: %{name: "no_stats"},
        score: 0.5,
        trajectories: [
          %{
            success?: true,
            steps: 3,
            runtime_logs: [
              %{phase: :recall, prints: [], tool_calls: []}
            ]
          }
        ]
      }

      output = DebugLog.format_parents([parent])

      refute output =~ "SIMILARITY"
    end
  end

  describe "format_stores/1" do
    test "formats vector and graph store summary" do
      memory = %{
        __vector_store: %{
          entries: %{
            1 => %{text: "obs1", collection: "spatial", vector: [], metadata: %{}},
            2 => %{text: "obs2", collection: "spatial", vector: [], metadata: %{}},
            3 => %{text: "obs3", collection: "objects", vector: [], metadata: %{}}
          },
          next_id: 4
        },
        __graph_store: %{
          "room_A" => MapSet.new(["room_B"]),
          "room_B" => MapSet.new(["room_A", "room_C"]),
          "room_C" => MapSet.new(["room_B"])
        }
      }

      output = DebugLog.format_stores(memory)

      assert output =~ "=== STORES after collection ==="
      assert output =~ "Vector store: 3 entries"
      assert output =~ "objects"
      assert output =~ "spatial"
      # Snapshot of recent entries
      assert output =~ "(spatial) obs"
      assert output =~ "Graph store: 3 nodes, 2 edges"
      assert output =~ "Nodes: room_A, room_B, room_C"
    end

    test "handles empty stores" do
      output = DebugLog.format_stores(%{})

      assert output =~ "Vector store: empty"
      assert output =~ "Graph store: empty"
    end
  end
end
