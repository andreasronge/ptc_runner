(ns orders "Order placement API." {:visibility :prompt})

(defn place
  "Return the standard total for an order."
  {:signature "(subtotal :int) -> {total :int}"}
  [subtotal]
  (let [total (pricing.tax/add-standard subtotal)]
    (if (= total (+ subtotal 20))
      {"total" total}
      (fail "standard total invariant failed"))))
