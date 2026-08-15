(ns debug.case
  "Structural startup context for one failed run. It co-locates evidence and frozen source without choosing a cause or repair."
  {:visibility :prompt})

(defn- projected-turn [turn]
  {"turn" (get turn "turn")
   "task" (get-in turn ["messages_added" 0 "content"])
   "outcome" (get turn "outcome")
   "generated"
   (mapv
     #(select-keys % ["evaluation_id" "parent_evaluation_id" "mission_name"
                      "source" "prelude_calls" "relationships"])
     (get turn "generated"))})

(defn context
  "Return a bounded structural case packet: terminal workflow error, directly nested evaluations and generated turns, the single nested mission capability result when present, and the exact frozen working set. Typed relationships remain available for expansion with debug.nav."
  {:signature "(run-id :string) -> :map"}
  [run-id]
  (let [listing (debug.nav/runs {"limit" 20})
        run (first (filter #(= run-id (get % "run_id")) (get listing "items")))
        errors (debug.nav/read run-id {"collection" "execution_errors" "limit" 20})
        failure (first (get errors "items"))
        workflow-evaluation-id (get failure "evaluation_id")]
    (if (or (nil? run) (nil? failure) (nil? workflow-evaluation-id))
      (fail "the selected run has no complete workflow failure to project")
      (let [nested
            (debug.nav/read
              run-id
              {"collection" "activity"
               "parent_evaluation_id" workflow-evaluation-id
               "limit" 100})
            turns
            (debug.nav/read
              run-id
              {"collection" "turns"
               "parent_evaluation_id" workflow-evaluation-id
               "limit" 100})
            projected-turns (mapv projected-turn (get turns "items"))
            generated-evaluation-ids
            (distinct
              (map #(get % "evaluation_id")
                   (mapcat #(get % "generated") projected-turns)))
            generated-pages
            (mapv
              #(debug.nav/read
                 run-id
                 {"collection" "generated_sources"
                  "evaluation_id" %
                  "limit" 20})
              generated-evaluation-ids)
            generated-sources (mapcat #(get % "items") generated-pages)
            mission-name (get-in projected-turns [0 "generated" 0 "mission_name"])
            calls
            (if (string? mission-name)
              (debug.nav/read
                run-id
                {"collection" "capability_calls"
                 "mission_name" mission-name
                 "limit" 100})
              {"items" []})
            single-call (if (= 1 (count (get calls "items")))
                          (first (get calls "items"))
                          nil)
            working-set (debug.workspace/changed run-id generated-sources)]
        {"run"
         (select-keys run ["run_id" "status" "terminal_reason" "duration_ms"
                           "error_count" "evaluations" "llm_calls"])
         "workflow_failure"
         (select-keys failure ["evaluation_id" "environment" "kind" "reason"
                               "relationships"])
         "directly_nested_activity"
         (mapv #(select-keys % ["sequence" "type" "data" "relationships"])
               (get nested "items"))
         "generated_turns" projected-turns
         "single_nested_capability_call"
         (if single-call
           (select-keys single-call ["capability_id" "mission_name" "name"
                                     "arguments" "result" "complete?"])
           nil)
         "working_set" (get working-set "files")
         "completeness"
         {"runs_truncated" (get listing "truncated")
          "errors_truncated" (get errors "truncated")
          "nested_activity_truncated" (get nested "truncated")
          "turns_complete" (get-in turns ["evidence" "complete?"])
          "turns_ambiguity_count" (get-in turns ["evidence" "ambiguity_count"])
          "generated_sources_truncated"
          (boolean (some #(get % "truncated") generated-pages))
          "capability_calls_truncated" (get calls "truncated")
          "working_set_complete" (get working-set "complete?")}}))))
