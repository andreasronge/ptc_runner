(ns resume "Resume a captured read-only investigation at one selected action." {:visibility :prompt})

(defn- evaluate [source]
  (let [r (tool/kernel-eval {:kind :source :source source :mission "evidence" :observation_chars 2048})]
    (if (= :ok (get r :status)) (get r :value) r)))

(defn- append-result [request action evaluation remaining]
  (update request "messages" conj
    {"role" "assistant" "content" (get action :rationale) "tool_calls" [(get action :public-tool-call)]}
    {"role" "tool" "tool_call_id" (get action :tool-call-id)
     "content" (str (if (= :continued (get evaluation :outcome))
                       (agent.feedback/success evaluation 2048)
                       (agent.feedback/evaluation-error evaluation))
                    "\n\n" (agent.feedback/turn-budget remaining nil))}))

(defn run "Restore the prefix and continue with a fixed remaining model budget." [input]
  (let [prefix (mapv evaluate (get input "prefix"))]
    (if (not (every? #(= :continued (get % :outcome)) prefix))
      (fail "captured prefix did not restore successfully")
      (loop [request (get input "request") response (get input "response")
             remaining (get input "remaining") evaluations []]
        (let [action (agent.native/normalize response 32768)]
          (if (not= :tool-call (get action :kind))
            (return {"status" "protocol_failure" "action" action "evaluations" evaluations})
            (let [evaluation (evaluate (get action :program))
                  steps (conj evaluations {"program" (get action :program) "evaluation" evaluation})
                  outcome (get evaluation :outcome)]
              (cond
                (= :returned outcome)
                (return {"status" "returned" "verdict" (get evaluation :value) "evaluations" steps})
                (= :failed outcome)
                (return {"status" "failed" "failure" (get evaluation :value) "evaluations" steps})
                (<= remaining 0)
                (return {"status" "budget_exhausted" "evaluations" steps})
                :else
                (let [next-request (append-result request action evaluation remaining)]
                  (recur next-request (llm/request next-request) (dec remaining) steps))))))))))
