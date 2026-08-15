(ns debug.feedback-entry-terminal-actions
  "Experiment entry that tests correction actions which terminate themselves."
  {:visibility :prompt})

(defn run [feedback]
  (return
    (debug.preloaded/run-feedback
      feedback
      "case-ambiguous"
      {"phases"
       [{"mission" "synthesize"
         "max_turns" 2}]
       "result_instruction"
       "Call exactly one top-level repair.terminal/abstain or repair.terminal/propose action. The action completes the correction itself; do not wrap it in return."
       "max_observation_chars" 8192
       "max_transcript_chars" 262144})))
