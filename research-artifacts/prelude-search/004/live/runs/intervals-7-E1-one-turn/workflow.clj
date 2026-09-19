(ns lab.search "Checked single-shot repair." {:visibility :prompt})
(defn run
  "Run one repair candidate."
  [input]
  (return [(agent.core/run-outcome
             (get-in input ["attempts" 0 "task"])
             {"mission" (get-in input ["attempts" 0 "mission"])
              "max_turns" 1
              "retain_programs" 1
              "return_contract" "repair"})]))
