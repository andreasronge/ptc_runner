(ns demo.agent "Viewer-demo entry over the installed agent loop." {:visibility :prompt})

(defn run [input]
  (agent.core/run (get input "task") {"max_turns" (get input "max_turns" 6)}))

(defn run-terminal-error [input]
  (let [outcome (agent.core/run-outcome
                  (get input "task")
                  {"max_turns" (get input "max_turns" 6)})]
    (fail {:kind :viewer-demo-terminal-error :agent-outcome outcome})))
