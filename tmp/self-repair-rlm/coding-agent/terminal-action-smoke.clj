(ns terminal-action-smoke
  "Provider-free proof that a correction action can terminate its caller."
  {:visibility :prompt})

(defn run [_input]
  (repair.terminal/abstain
    "smoke-run"
    "The evidence does not distinguish one repair."
    ["One mismatch was observed."]
    ["A distinguishing invariant is missing."]))
