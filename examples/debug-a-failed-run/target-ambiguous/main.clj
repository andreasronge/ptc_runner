(ns main "Deterministic order-total entry for the underdetermined variant." {:visibility :prompt})

;; Mirrors target/main.clj: the order and the caller's requirement are embedded
;; in the evaluated program, so the frozen evidence records exactly what the
;; failing call was asked to do.
(defn- check-source [subtotal required]
  (str "(let [quote (orders/place " subtotal ")]"
       " (if (= (get quote \"total\") " required ")"
       " quote"
       " (fail {:kind \"order-total-mismatch\"})))"))

(defn run
  "Price one order against the total its caller requires."
  {:signature "(input :map) -> :map"}
  [input]
  (let [required (get input "required_total")
        outcome (kernel/eval-source
                  "billing"
                  (check-source (get input "subtotal") required))
        quote (get outcome "value")]
    (if (= (get quote "total") required)
      (return quote)
      (fail {:kind "order-total-mismatch"}))))
