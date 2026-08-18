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

;; An explicit run id pins the packet to one capture; without one, the most
;; recent failed run is the incident, exactly as the deterministic walk
;; selects it. The pinned lookup filters server-side, so a capture holding
;; more runs than one page cannot make a valid incident report as missing.
(defn- selected-run [run-id]
  (let [listing (debug.nav/runs
                  (if (string? run-id)
                    {"run_id" run-id "limit" 1}
                    {"status" "error" "limit" 1}))]
    {"run" (first (get listing "items"))
     "truncated" (get listing "truncated")}))

(defn context
  "Return a bounded structural case packet: terminal workflow error, directly nested evaluations and generated turns, the single nested mission capability result when present, and the exact frozen working set. Typed relationships remain available for expansion with debug.nav."
  {:signature "(run-id :string?) -> :map"}
  [requested-run-id]
  (let [selection (selected-run requested-run-id)
        run (get selection "run")
        run-id (get run "run_id")
        errors (if (string? run-id)
                 (debug.nav/read run-id {"collection" "execution_errors" "limit" 20})
                 {"items" []})
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
            ;; A deterministic workflow evaluates its generated program
            ;; directly under the failing evaluation; an agent workflow
            ;; records it beneath a turn. Collect both shapes, so the packet
            ;; is not empty merely because the incident had no model turns.
            direct-generated
            (debug.nav/read
              run-id
              {"collection" "generated_sources"
               "parent_evaluation_id" workflow-evaluation-id
               "limit" 20})
            turn-evaluation-ids
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
              turn-evaluation-ids)
            direct-items (get direct-generated "items")
            direct-ids (map #(get % "evaluation_id") direct-items)
            generated-sources
            (concat
              direct-items
              (remove
                #(some (fn [id] (= id (get % "evaluation_id"))) direct-ids)
                (mapcat #(get % "items") generated-pages)))
            mission-name (get (first generated-sources) "mission_name")
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
            working-set (debug.workspace/changed run-id generated-sources)
            ;; Generated-program relationships reach the mission components
            ;; they called, but a workflow-control failure may live in the
            ;; host-authored workflow that routed values between those calls.
            ;; Include the complete bounded workflow environment without
            ;; naming a suspect; candidate selection remains the model's job.
            workflow-sources
            (debug.nav/read
              run-id
              {"collection" "prelude_sources"
               "environment" "workflow"
               "limit" 100})]
        {"run"
         (select-keys run ["run_id" "status" "terminal_reason" "duration_ms"
                           "error_count" "evaluations" "llm_calls"])
         "workflow_failure"
         (select-keys failure ["evaluation_id" "environment" "kind" "reason"
                               "details" "relationships"])
         "directly_nested_activity"
         (mapv #(select-keys % ["sequence" "type" "data" "relationships"])
               (get nested "items"))
         "generated_turns" projected-turns
         "generated_sources"
         (mapv
           #(select-keys % ["evaluation_id" "parent_evaluation_id"
                            "mission_name" "source" "relationships"])
           generated-sources)
         "single_nested_capability_call"
         (if single-call
           (select-keys single-call ["capability_id" "mission_name" "name"
                                     "arguments" "result" "complete?"])
           nil)
         "working_set" (get working-set "files")
         "workflow_sources"
         (mapv
           #(select-keys % ["component_id" "environment" "mission_name"
                            "source_hash" "source" "relationships"])
           (get workflow-sources "items"))
         "completeness"
         {"runs_truncated" (get selection "truncated")
          "errors_truncated" (get errors "truncated")
          "nested_activity_truncated" (get nested "truncated")
          "turns_complete" (get-in turns ["evidence" "complete?"])
          "turns_ambiguity_count" (get-in turns ["evidence" "ambiguity_count"])
          "generated_sources_truncated"
          (boolean (some #(get % "truncated") generated-pages))
          "capability_calls_truncated" (get calls "truncated")
          "working_set_complete" (get working-set "complete?")
          "workflow_sources_complete"
          (and (not (get workflow-sources "truncated"))
               (nil? (get workflow-sources "next_cursor")))}}))))
