(ns main "One final decision after replaying read-only navigation state." {:visibility :prompt})

(defn- evaluate [source]
  (let [r (tool/kernel-eval {:kind :source :source source :mission "evidence" :observation_chars 2048})]
    (if (= :ok (get r :status)) (get r :value) r)))

(defn run "Restore recorded programs, execute the sampled action, and allow at most one final model call." [input]
  (let [prefix (mapv evaluate (get input "prefix"))
        response (get input "response")
        calls (get response "tool_calls")
        first-result (evaluate (get-in (first calls) ["args" "program"]))
        common {"parent_trial" (get input "parent_trial")
                "prefix_outcomes" (mapv #(get % :outcome) prefix)
                "first_evaluation" first-result}]
    (if (= :returned (get first-result :outcome))
      (return (assoc common "new_model_calls" 0 "final_evaluation" first-result))
      (let [feedback (if (= :continued (get first-result :outcome))
                       (agent.feedback/success first-result 2048)
                       (agent.feedback/evaluation-error first-result))
            request (update (get input "request") "messages" conj
                      {"role" "assistant" "content" (get response "content") "tool_calls" calls}
                      {"role" "tool" "tool_call_id" (get (first calls) "id")
                       "content" (str feedback "\n\n" (agent.feedback/turn-budget 1 nil))})
            next-response (llm/request request)
            next-calls (get next-response "tool_calls")]
        (if (and (= 1 (count next-calls))
                 (= "run_ptc_lisp" (get (first next-calls) "name"))
                 (string? (get-in (first next-calls) ["args" "program"])))
          (return (assoc common "new_model_calls" 1 "response" next-response
                         "final_evaluation" (evaluate (get-in (first next-calls) ["args" "program"]))))
          (return (assoc common "new_model_calls" 1 "response" next-response
                         "protocol_failure" true)))))))
