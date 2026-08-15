(ns debug.feedback-entry
  "Experiment entry that binds a repair feedback envelope to one correction policy."
  {:visibility :prompt})

(defn run [feedback]
  (return
    (debug.preloaded/run-feedback
      feedback
      "case-ambiguous"
      {"phases"
       [{"mission" "synthesize"
         "max_turns" 2
         "terminal_only" true}]
       "max_observation_chars" 8192
       "max_transcript_chars" 262144})))
