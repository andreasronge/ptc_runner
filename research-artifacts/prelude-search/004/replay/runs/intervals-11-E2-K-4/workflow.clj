(ns lab.search "Checked parallel repair." {:visibility :prompt})
(defn- propose [attempt]
  (agent.core/run-outcome
    (get attempt "task")
    {"mission" (get attempt "mission") "max_turns" 1 "retain_programs" 1 "return_contract" "repair"}))
(defn run
  "Generate candidates in parallel."
  [input]
  (return (pmap propose (get input "attempts"))))
