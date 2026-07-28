(ns agent.main "Generic workflow entry for scripted agents." {:visibility :prompt})

(defn run
  "Runs `agent.core` from a manifest input, so a manifest can name this entry
  directly instead of every application repeating the same wrapper.

  `task` is the workflow's instruction and `agent` its loop configuration. Both
  come from input, so this stays domain-blind: it never learns what the task is
  about, and adding a new application needs no change here. The application
  entry returns the model-authored value directly so a manifest result contract
  describes that value rather than agent.core's default success envelope."
  [input]
  (agent.core/run
    (get input "task")
    (assoc (get input "agent") "result_envelope" false)))
