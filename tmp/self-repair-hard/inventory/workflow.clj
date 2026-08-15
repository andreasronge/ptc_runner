(ns repair.inventory "Runs one bounded inventory mission.")

(defn run [input]
  (return
    (agent.core/run-result-value
      (get input "task")
      {"mission" "default"
       "max_turns" 2})))
