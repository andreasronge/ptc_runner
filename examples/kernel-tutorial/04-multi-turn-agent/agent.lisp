(ns tutorial.multi-turn "Two-turn agent continuation tutorial." {:visibility :prompt})

(defn run [input]
  (agent.core/run (get input "task") {"max_turns" 2}))
