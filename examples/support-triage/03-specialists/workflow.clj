(ns triage.workflow "A triage specialist scores tickets; an escalation specialist routes them.")

(defn- returned-value [outcome stage]
  (if (= :returned (get outcome :status))
    (get outcome :value)
    (fail {:status :error :kind :agent-failed :reason stage :outcome outcome})))

(defn run [input]
  (let [ranked-outcome (agent.core/run-outcome
                         (get input "triage_task")
                         {"mission" "triage" "max_turns" 4})
        ranked (returned-value ranked-outcome "triage")
        report (agent.core/run-result-value
                 (str (get input "escalation_task")
                      "\n\nBreached tickets, highest priority first:\n"
                      (pr-str ranked))
                 {"mission" "escalation" "max_turns" 4})]
    (return report)))
