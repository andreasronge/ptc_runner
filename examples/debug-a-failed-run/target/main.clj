(ns main "Deterministic order-total entry." {:visibility :prompt})

;; Both the order and the caller's requirement are part of the program the
;; mission evaluates, so the frozen evidence records exactly what the failing
;; call was asked to do. A capture that referenced `data/params` instead would
;; retain the check but not the values it ran on, which is not enough to
;; distinguish a wrong input from a wrong component.
(defn- check-source [subtotal required]
  (str "(let [quote (orders/place {\"subtotal\" " subtotal "})]"
       " (if (= (get quote \"total\") " required ")"
       " quote"
       " (fail {:kind \"order-total-mismatch\"})))"))

(defn run
  "Price one order against the total its caller requires."
  {:signature "(input :map) -> :map"}
  [input]
  (let [required (get input "required_total")
        outcome (kernel/eval-source
                  "pricing"
                  (check-source (get input "subtotal") required))
        quote (get outcome "value")]
    (if (= (get quote "total") required)
      (return quote)
      ;; Only a one-way fingerprint of this kind reaches the canonical trace.
      (fail {:kind "order-total-mismatch"}))))
