(ns agent.core
  "Minimal native-action kernel loop."
  {:visibility :prompt})

(defn- action-summary
  "Return the default-safe trace projection for one model action."
  [action]
  (select-keys action ["kind" "reason" "model" "provider" "transport_error"]))

(defn run-mission
  "Run the minimal native-action loop."
  [mission cfg]
  (loop [turn 0
         messages [(agent.prompt/task-message mission cfg)]
         actions []]
    (if (>= turn (cfg "max_turns"))
      (fail {"reason" "turn_limit_exceeded" "turns" turn})
      (let [action (tool/llm-complete {"system" (agent.prompt/system-message cfg)
                                       "messages" messages
                                       "turn" turn})]
        (tool/log {"event" "action" "turn" turn "action" action})
        (let [actions2 (conj actions (action-summary action))]
          (case (action "kind")
          "tool_call"
            (let [result (tool/eval-program {"program" (action "program")
                                             "turn" turn})]
              (tool/log {"event" "eval" "turn" turn "result" result})
              (case (result "status")
                "return" (return {"value" (result "value")
                                  "trace" {"turns" (inc turn)
                                           "actions" actions2}})
                "fail" (fail {"reason" "model_program_failed" "eval" result})
                (recur (inc turn)
                       (conj messages
                             {"role" "assistant" "tool_calls" [(action "public_tool_call")]}
                             {"role" "tool" "tool_call_id" (action "tool_call_id")
                              "content" (agent.feedback/eval-feedback result cfg)})
                       actions2)))
          "protocol_error"
            (recur (inc turn)
                   (conj messages
                         {"role" "user"
                          "content" (agent.feedback/protocol-error action cfg)})
                   actions2)
          "transport_error"
            (fail {"reason" "llm_transport_error" "error" action})
          (fail {"reason" "unknown_action" "action" action})))))))
