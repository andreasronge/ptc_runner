(ns triage.workflow "One bounded question over granted ticket data.")

(defn run [input]
  (agent.core/run (get input "task") {"max_turns" 3}))
