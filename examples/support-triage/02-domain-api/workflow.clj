(ns triage.workflow "One bounded run composing the triage policy over granted data.")

(defn run [input]
  (agent.core/run (get input "task") {"max_turns" 4}))
