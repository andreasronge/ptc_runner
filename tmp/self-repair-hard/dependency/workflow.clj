(ns repair.orders "Runs one bounded order mission.")

(defn run [input]
  (return
    (agent.core/run-result-value
      (get input "task")
      {"mission" "default"
       "max_turns" 2})))
