(ns agent.main "Generic workflow entry for scripted agents." {:visibility :prompt})

(defn run
  "Runs `agent.core` from a manifest input, so a manifest can name this entry
  directly instead of every application repeating the same wrapper.

  `task` is the workflow's instruction and `agent` its loop configuration. Both
  come from input, so this stays domain-blind: it never learns what the task is
  about, and adding a new application needs no change here. The application
  entry returns the model-authored value directly so a manifest result contract
  describes that value rather than agent.core's default success envelope."
  {:signature "(input {task :string, agent {model :string?, mission :string?, max_turns :int?, max_program_chars :int?, max_observation_chars :int?, max_transcript_chars :int?, consolidate_at_turns_remaining :int?}}) -> :any"}
  [input]
  (return
    (agent.core/run-result-value
      (get input "task")
      (get input "agent"))))
