(ns repair.target "Runs one bounded claim-submission mission.")

(defn run [input]
  (return
    (agent.core/run-result-value
      (get input "task")
      {"mission" "default"
       "max_turns" 2})))
