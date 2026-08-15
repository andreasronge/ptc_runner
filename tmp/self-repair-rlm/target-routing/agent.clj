(ns target.agent "Generate one delivery API call through the normal agent loop." {:visibility :prompt})

(defn run [input]
  (agent.core/run
    (get input "task")
    {"max_turns" 1
     "max_observation_chars" 8192
     "max_transcript_chars" 65536}))
