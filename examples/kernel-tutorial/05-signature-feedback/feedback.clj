(ns tutorial.signature-feedback "Show contract feedback without calling a model.")

(defn run [_input]
  (let [invalid (kernel/eval-source
                  "default"
                  "(tutorial.signatures/double \"21\")")
        corrected (kernel/eval-source
                    "default"
                    "(return (tutorial.signatures/double 21))")]
    (return
      {"invalid_evaluation" invalid
       "model_feedback" (agent.feedback/evaluation-error invalid)
       "corrected_evaluation" corrected})))
