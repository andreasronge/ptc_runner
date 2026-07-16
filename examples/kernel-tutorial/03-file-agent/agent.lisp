(ns tutorial.agent "Thin manifest entry over the installed agent loop." {:visibility :prompt})

(defn run [input]
  (agent.core/run (get input "task") {"max_turns" 4}))
