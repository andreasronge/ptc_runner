(ns main "Deterministic order-total entry." {:visibility :prompt})

;; The caller's requirement is part of the program the mission evaluates, so
;; the frozen evidence records what the failing call was actually asked to do.
(defn- check-source [required]
  (str "(let [quote (orders/place data/params)]"
       " (if (= (get quote \"total\") " required ")"
       " quote"
       " (fail {:kind \"order-total-mismatch\"})))"))

(defn run
  "Price one order against the total its caller requires."
  {:signature "(input :map) -> :map"}
  [input]
  (let [required (get input "required_total")
        outcome (kernel/eval-source-with "pricing" (check-source required) input)
        quote (get outcome "value")]
    (if (= (get quote "total") required)
      (return quote)
      ;; Only a one-way fingerprint of this kind reaches the canonical trace.
      (fail {:kind "order-total-mismatch"}))))
