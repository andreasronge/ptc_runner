(mapv
  (fn [r]
    (let [id (get r "run_id") o (analysis/open id) v (get-in o ["result" "value"])
          final (get v "final_evaluation")
          verdict (get final "value")
          xs (get (analysis/read id {"collection" "model_exchanges" "limit" 2}) "items")]
      {"run_id" id "parent_trial" (get v "parent_trial")
       "status" (get r "status") "llm_calls" (get r "llm_calls")
       "duration_ms" (get r "duration_ms") "spend" (get-in o ["run" "llm_spend"])
       "prefix_count" (count (get v "prefix_outcomes"))
       "prefix_continued" (every? #(= "continued" %) (get v "prefix_outcomes"))
       "first_outcome" (get-in v ["first_evaluation" "outcome"])
       "protocol_failure" (get v "protocol_failure")
       "final_outcome" (get final "outcome") "final_kind" (get final "kind")
       "verdict" verdict "final_details" (get final "details")
       "exchange_count" (count xs) "exchanges_complete" (every? #(get % "complete?") xs)
       "programs" (mapv #(get-in % ["args" "program"]) (get-in v ["response" "tool_calls"]))}))
  (get (analysis/runs {"limit" 5}) "items"))
