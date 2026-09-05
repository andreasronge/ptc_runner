;; Run with ptc repl --project CELL.ptc-project.json
;; --profile private-run-analysis-v2 --private-unattended --preview-chars 16000
;; scripts/labs/debug-repair-showcase/analyze-navigation.clj
;; This queries the correlated capture through PTC; it does not parse files.
(defn summarize-run [row]
  (let [run-id (get row "run_id")
        opened (analysis/open run-id)
        run (get opened "run")
        page (analysis/read run-id {"collection" "turns" "limit" 30})
        turns (get page "items")
        feedback (mapcat #(get % "feedback") turns)
        programs (mapcat #(get % "generated") turns)]
    (merge
      (select-keys run ["run_id" "status" "terminal_reason" "llm_calls"
                        "llm_spend" "duration_ms"])
      (select-keys (get-in opened ["result" "value"])
                   ["decision" "component_id" "cause"])
      {"model" (some #(get-in % ["acquisition" "resolved_model"])
                     (get run "connector_snapshots"))
       "turn_page_complete" (and (not (get page "truncated"))
                                 (nil? (get page "next_cursor")))
       "feedback_with_truncated_preview"
       (count (filter #(includes? (get % "content" "") "Preview truncated") feedback))
       "programs_with_println"
       (count (filter #(includes? (get % "source" "") "println") programs))})))

(mapv summarize-run (get (analysis/runs {"limit" 10}) "items"))
