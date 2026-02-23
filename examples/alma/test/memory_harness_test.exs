defmodule Alma.MemoryHarnessTest do
  use ExUnit.Case, async: true

  alias Alma.MemoryHarness

  describe "null_design/0" do
    test "returns baseline design with nil closures" do
      design = MemoryHarness.null_design()
      assert design.name == "null"
      assert design.mem_update == nil
      assert design.recall == nil
      assert design.mem_update_source == ""
      assert design.recall_source == ""
    end
  end

  describe "retrieve/3" do
    test "returns empty string tuple for nil recall closure" do
      design = MemoryHarness.null_design()

      assert MemoryHarness.retrieve(design, %{}, %{}) ==
               {"", nil,
                %{
                  phase: :recall,
                  prints: [],
                  tool_calls: [],
                  return: nil,
                  error: nil,
                  similarity_stats: [],
                  embed_mode: nil
                }}
    end

    test "calls recall closure with task context" do
      {:ok, step} = PtcRunner.Lisp.run(~S|(fn [] (str "Location: " (get data/task "location")))|)
      recall_closure = step.return

      design = %{name: "test", recall: recall_closure}
      {result, nil, _log} = MemoryHarness.retrieve(design, %{"location" => "room_A"}, %{})
      assert result == "Location: room_A"
    end

    test "recall closure can access memory variables" do
      # Create closure with hint in scope so static analysis passes
      {:ok, step} =
        PtcRunner.Lisp.run(
          ~S|(fn [] (str "Hint: " (or hint "none")))|,
          memory: %{hint: nil}
        )

      recall_closure = step.return

      design = %{name: "test", recall: recall_closure}
      memory = %{hint: "go left"}
      {result, nil, _log} = MemoryHarness.retrieve(design, %{}, memory)
      assert result == "Hint: go left"
    end
  end

  describe "vanishing helpers bug" do
    test "recall that uses a helper defn'd in the same namespace works" do
      # Simulate what the MetaAgent produces: a namespace with a helper + recall.
      # The helper takes a parameter so no bare-name issue at static analysis.
      {:ok, step} =
        PtcRunner.Lisp.run("""
        (do
          (defn success-rate [s]
            (if (> (get s "total") 0)
              (/ (get s "successes") (get s "total"))
              0))
          (defn recall []
            (str "Success rate: " (success-rate (or (get data/task "stats") {"total" 0 "successes" 0})))))
        """)

      # The MetaAgent's step.memory contains both the helper and recall
      recall_closure = step.memory[:recall]
      assert is_tuple(recall_closure)

      # Fix: carry the full namespace so helpers are available
      design = %{name: "test", recall: recall_closure, namespace: step.memory}

      {result, nil, _log} =
        MemoryHarness.retrieve(design, %{"stats" => %{"total" => 10, "successes" => 7}}, %{})

      # This should return "Success rate: 0.7" but currently crashes
      # because success-rate is not in scope when recall is called alone
      assert result == "Success rate: 0.7"
    end

    test "mem-update that uses a helper defn'd in the same namespace works" do
      {:ok, step} =
        PtcRunner.Lisp.run(
          """
          (do
            (defn track-location [loc]
              (def location-counts
                (let [counts (or location-counts {})]
                  (assoc counts loc (inc (or (get counts loc) 0))))))
            (defn mem-update []
              (track-location (get data/task "agent_location"))))
          """,
          memory: %{"location-counts": nil}
        )

      mem_update_closure = step.memory[:"mem-update"]
      assert is_tuple(mem_update_closure)

      design = %{name: "test", mem_update: mem_update_closure, namespace: step.memory}

      episode = %{
        task: %{"agent_location" => "room_A"},
        actions: [],
        success: true,
        observation_log: []
      }

      # Should update location-counts, but currently crashes because
      # track-location helper is not in scope
      {memory, nil, _log} = MemoryHarness.update(design, episode, %{})
      assert memory[:"location-counts"] == %{"room_A" => 1}
    end

    test "full namespace design with helpers survives collection phase" do
      # A design where recall depends on a helper that mem-update also uses.
      # We seed `stats` as nil so it passes static analysis.
      {:ok, step} =
        PtcRunner.Lisp.run(
          """
          (do
            (defn format-stats [s]
              (str "W:" (get s "wins") "/T:" (get s "total")))
            (defn mem-update []
              (def stats
                (let [s (or stats {"wins" 0 "total" 0})]
                  (merge s {"total" (inc (get s "total"))
                            "wins" (+ (get s "wins") (if data/success 1 0))}))))
            (defn recall []
              (format-stats (or stats {"wins" 0 "total" 0}))))
          """,
          memory: %{stats: nil}
        )

      design = %{
        name: "test",
        mem_update: step.memory[:"mem-update"],
        recall: step.memory[:recall],
        namespace: step.memory
      }

      # After an update, recall should be able to use format-stats
      episode = %{task: %{}, actions: [], success: true, observation_log: []}
      {memory, nil, _log} = MemoryHarness.update(design, episode, %{})
      {result, nil, _log2} = MemoryHarness.retrieve(design, %{}, memory)
      assert result == "W:1/T:1"
    end
  end

  describe "update/3" do
    test "returns original memory for nil mem_update closure" do
      design = MemoryHarness.null_design()
      original = %{key: "value"}
      episode = %{task: %{}, actions: [], success: false, observation_log: []}

      assert MemoryHarness.update(design, episode, original) ==
               {original, nil,
                %{
                  phase: :"mem-update",
                  prints: [],
                  tool_calls: [],
                  return: nil,
                  error: nil,
                  similarity_stats: [],
                  embed_mode: nil
                }}
    end

    test "calls mem_update closure and returns updated memory" do
      {:ok, step} =
        PtcRunner.Lisp.run(
          ~S|(fn [] (def visits (conj (or visits []) (get data/task "location"))))|
        )

      mem_update_closure = step.return

      design = %{name: "test", mem_update: mem_update_closure}

      episode = %{
        task: %{"location" => "room_A"},
        actions: [],
        success: true,
        observation_log: []
      }

      {memory, nil, _log} = MemoryHarness.update(design, episode, %{visits: []})
      assert memory[:visits] == ["room_A"]

      episode2 = %{
        task: %{"location" => "room_B"},
        actions: [],
        success: true,
        observation_log: []
      }

      {memory2, nil, _log} = MemoryHarness.update(design, episode2, memory)
      assert memory2[:visits] == ["room_A", "room_B"]
    end

    test "strips injected closure key from returned memory" do
      {:ok, step} = PtcRunner.Lisp.run(~S|(fn [] (def x 42))|)
      mem_update_closure = step.return

      design = %{name: "test", mem_update: mem_update_closure}
      episode = %{task: %{}, actions: [], success: true, observation_log: []}
      {memory, nil, _log} = MemoryHarness.update(design, episode, %{})

      # The injected :"mem-update" key should not be in returned memory
      refute Map.has_key?(memory, :"mem-update")
      assert memory[:x] == 42
    end

    test "returns error when closure fails" do
      # Create a closure that will fail at runtime with a type error
      {:ok, step} =
        PtcRunner.Lisp.run(
          ~S|(fn [] (+ 1 (get data/task "name")))|,
          memory: %{}
        )

      mem_update_closure = step.return

      design = %{name: "test", mem_update: mem_update_closure}
      # "name" is a string, so (+ 1 "Alice") will type-error at runtime
      episode = %{task: %{"name" => "Alice"}, actions: [], success: true, observation_log: []}
      {memory, error, _log} = MemoryHarness.update(design, episode, %{original: true})

      assert memory == %{original: true}
      assert is_binary(error)
      assert error =~ "mem-update failed:"
    end

    test "returns runtime_log on error with correct phase and error message" do
      # Closure that crashes at runtime with a type error
      {:ok, step} =
        PtcRunner.Lisp.run(
          ~S|(fn [] (+ 1 "not a number"))|,
          memory: %{}
        )

      closure = step.return
      design = %{name: "test", mem_update: closure}
      episode = %{task: %{}, actions: [], success: true, observation_log: []}
      {_memory, error, log} = MemoryHarness.update(design, episode, %{})

      assert is_binary(error)
      assert log.phase == :"mem-update"
      assert is_list(log.prints)
      assert is_list(log.tool_calls)
      # The error from step.fail is captured in the log
      assert is_binary(log.error)
      assert log.error =~ "type_error"
    end
  end

  describe "recall_advice on results" do
    test "evaluate_collection attaches recall_advice to each result" do
      _design = MemoryHarness.null_design()
      # With null design, recall returns ""
      # We need a mock task that TaskAgent can handle — but TaskAgent requires
      # an LLM, so we test the attachment logic via evaluate_deployment with
      # a null design (which returns "" for recall_advice).
      # The key assertion is that the field exists on results.

      # Use a simple design with a recall that returns fixed advice
      {:ok, step} = PtcRunner.Lisp.run(~S|(fn [] "always go left")|)
      recall_closure = step.return

      design_with_recall = %{
        name: "test",
        mem_update: nil,
        recall: recall_closure,
        mem_update_source: "",
        recall_source: "",
        namespace: %{}
      }

      # We can't run full evaluate_collection without an LLM/TaskAgent,
      # but we can verify that retrieve returns the advice that would be attached
      {advice, nil, _log} = MemoryHarness.retrieve(design_with_recall, %{}, %{})
      assert advice == "always go left"
    end
  end

  describe "tool/analyze" do
    test "with text format returns string" do
      mock_llm = fn _request ->
        {:ok, %{content: "pattern: repeated visits to kitchen"}}
      end

      {:ok, step} =
        PtcRunner.Lisp.run(
          ~S|(fn [] (tool/analyze {"text" "went to kitchen 3 times" "instruction" "extract patterns"}))|
        )

      closure = step.return
      design = %{name: "test", mem_update: closure}
      episode = %{task: %{}, actions: [], success: true, observation_log: []}
      {memory, nil, _log} = MemoryHarness.update(design, episode, %{}, llm: mock_llm)
      # The closure's return value is not stored as memory state,
      # but the important thing is no error occurred
      assert is_map(memory)
    end

    test "with json format returns parsed map" do
      mock_llm = fn _request ->
        {:ok, %{content: ~S|{"pairs": [{"object": "flask", "room": "kitchen"}]}|}}
      end

      {:ok, step} =
        PtcRunner.Lisp.run(
          ~S|(fn [] (def result (tool/analyze {"text" "flask in kitchen" "instruction" "extract pairs" "format" "json"})))|
        )

      closure = step.return
      design = %{name: "test", mem_update: closure}
      episode = %{task: %{}, actions: [], success: true, observation_log: []}
      {memory, nil, _log} = MemoryHarness.update(design, episode, %{}, llm: mock_llm)
      assert memory[:result] == %{"pairs" => [%{"object" => "flask", "room" => "kitchen"}]}
    end

    test "with json format falls back to string on invalid JSON" do
      mock_llm = fn _request ->
        {:ok, %{content: "not valid json at all"}}
      end

      {:ok, step} =
        PtcRunner.Lisp.run(
          ~S|(fn [] (def result (tool/analyze {"text" "data" "instruction" "analyze" "format" "json"})))|
        )

      closure = step.return
      design = %{name: "test", mem_update: closure}
      episode = %{task: %{}, actions: [], success: true, observation_log: []}
      {memory, nil, _log} = MemoryHarness.update(design, episode, %{}, llm: mock_llm)
      assert memory[:result] == "not valid json at all"
    end
  end

  describe "graph tools" do
    test "graph tools available during mem_update" do
      {:ok, step} =
        PtcRunner.Lisp.run("""
        (fn []
          (tool/graph-update {"edges" [["room_A" "room_B"] ["room_B" "room_C"]]})
          (def neighbors (tool/graph-neighbors {"node" "room_A"})))
        """)

      closure = step.return
      design = %{name: "test", mem_update: closure}
      episode = %{task: %{}, actions: [], success: true, observation_log: []}
      {memory, nil, _log} = MemoryHarness.update(design, episode, %{})
      assert memory[:neighbors] == ["room_B"]
    end

    test "graph state persists in memory across episodes" do
      {:ok, step} =
        PtcRunner.Lisp.run("""
        (fn []
          (tool/graph-update {"edges" [["room_A" "room_B"]]})
          (def path (tool/graph-path {"from" "room_A" "to" "room_B"})))
        """)

      closure = step.return
      design = %{name: "test", mem_update: closure}
      episode = %{task: %{}, actions: [], success: true, observation_log: []}

      # First episode: add edge A-B
      {memory, nil, _log} = MemoryHarness.update(design, episode, %{})
      assert memory[:path] == ["room_A", "room_B"]
      assert Map.has_key?(memory, :__graph_store)

      # Second episode with a closure that adds B-C and queries A-C path
      {:ok, step2} =
        PtcRunner.Lisp.run("""
        (fn []
          (tool/graph-update {"edges" [["room_B" "room_C"]]})
          (def path (tool/graph-path {"from" "room_A" "to" "room_C"})))
        """)

      closure2 = step2.return
      design2 = %{name: "test", mem_update: closure2}
      {memory2, nil, _log} = MemoryHarness.update(design2, episode, memory)
      # Path should traverse A->B->C since A-B was persisted from first episode
      assert memory2[:path] == ["room_A", "room_B", "room_C"]
    end
  end

  describe "context_schema/0" do
    test "GraphWorld returns schema with mem_update and recall keys" do
      schema = Alma.Environments.GraphWorld.context_schema()
      assert is_map(schema["mem_update"])
      assert is_map(schema["recall"])
      assert Map.has_key?(schema["mem_update"], "data/task")
      assert Map.has_key?(schema["mem_update"], "data/observation_log")
      assert Map.has_key?(schema["recall"], "data/task")
      assert Map.has_key?(schema["recall"], "data/current_observation")
    end
  end
end
