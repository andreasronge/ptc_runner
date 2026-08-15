(ns main "Deterministic evidence-collection entry." {:visibility :prompt})

(defn run
  "Collect immutable evidence about the most recent failed run."
  {:signature "(input :map) -> :map"}
  [input]
  (return
    (get
      (kernel/eval-source-with "evidence" "(evidence.walk/collect data/params)" input)
      "value")))
