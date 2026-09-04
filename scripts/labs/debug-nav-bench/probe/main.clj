(ns main "Deterministic probe of the terminal actions." {:visibility :prompt})

(defn run
  "Evaluate one terminal action in the evidence mission and return the raw evaluation."
  {:signature "(input :map) -> :map"}
  [input]
  (let [src (if (= (get input "action") "diagnose")
              "(debug.terminal/diagnose data/params)"
              "(debug.terminal/abstain data/params)")]
    (return (kernel/eval-source-with "evidence" src (get input "report")))))
