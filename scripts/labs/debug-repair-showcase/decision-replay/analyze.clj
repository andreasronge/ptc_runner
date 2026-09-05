(mapv
  (fn [r]
    (let [id (get r "run_id") opened (analysis/open id)
          value (get-in opened ["result" "value"])
          exchanges (analysis/read id {"collection" "model_exchanges" "limit" 2})
          x (first (get exchanges "items"))]
      {"run_id" id "status" (get r "status")
       "duration_ms" (get r "duration_ms") "llm_calls" (get r "llm_calls")
       "spend" (get-in opened ["run" "llm_spend"])
       "exchange_complete" (and (= 1 (count (get exchanges "items"))) (get x "complete?"))
       "request_message_count" (count (get-in x ["arguments" "messages"]))
       "programs" (mapv #(get-in % ["args" "program"]) (get value "tool_calls"))
       "response_error" (get value "error")
       "response_content" (get value "content")}))
  (get (analysis/runs {"limit" 10}) "items"))
