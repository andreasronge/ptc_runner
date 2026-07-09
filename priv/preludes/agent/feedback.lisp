(ns agent.feedback
  "Kernel feedback policy."
  {:visibility :prompt})

(defn protocol-error
  "Render feedback for a model action that did not match the native protocol."
  [action cfg]
  (str "Protocol error: " (action "reason")
       ". Call run_ptc_lisp with exactly one valid program string."))

(defn eval-feedback
  "Render feedback for a program that did not return."
  [result cfg]
  (let [payload {"type" "ptc_lisp_eval_feedback"
                 "instruction" "Previous PTC-Lisp program did not return successfully. Call run_ptc_lisp again with a corrected program that ends in (return value)."
                 "untrusted_eval_result" result}]
    (or (json/generate-string payload)
        (str "PTC-Lisp eval feedback: " (result "status") " " (result "reason")))))
