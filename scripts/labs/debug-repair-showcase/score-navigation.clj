;; Load analyze-navigation.clj first with --load, then evaluate this script.
;; Grouping is descriptive; inspect cause/evidence before calling a verdict correct.
(let [rows (mapv summarize-run (get (analysis/runs {"limit" 10}) "items"))
      calls (mapv #(get % "llm_calls") rows)
      costs (mapv #(get-in % ["llm_spend" "total_cost" "microunits"]) rows)
      times (mapv #(get % "duration_ms") rows)]
  {"samples" (count rows)
   "outcomes" (frequencies (map #(get % "status") rows))
   "decisions" (frequencies (map #(get % "decision" "unfinished") rows))
   "components" (frequencies (map #(get % "component_id" "none") rows))
   "failures" (vec (keep #(get % "terminal_reason") rows))
   "calls" calls
   "duration_ms" times
   "cost_microusd" costs
   "truncated_feedbacks" (mapv #(get % "feedback_with_truncated_preview") rows)
   "println_programs" (mapv #(get % "programs_with_println") rows)
   "complete_turn_pages" (every? #(get % "turn_page_complete") rows)})
