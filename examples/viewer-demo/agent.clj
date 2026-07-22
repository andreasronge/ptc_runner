(ns demo.agent "Viewer-demo entry over the installed agent loop." {:visibility :prompt})

(defn run [input]
  (agent.core/run (get input "task") {"max_turns" (get input "max_turns" 6)}))
