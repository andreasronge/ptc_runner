(ns debug.feedback-entry-actions
  "Experiment entry that tests typed correction-decision constructors."
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
       "result_instruction"
       "Return the value of exactly one repair.action/abstain or repair.action/propose call. Do not return a decision keyword or string directly."
       "max_observation_chars" 8192
       "max_transcript_chars" 262144})))
