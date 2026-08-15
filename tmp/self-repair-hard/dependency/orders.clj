(ns orders "Order placement API." {:visibility :prompt})

(defn place
  "Return an order total after adding the fixed tax of 20."
  {:signature "(subtotal :int) -> {total :int}"}
  [subtotal]
  (let [total (pricing.tax/add-fixed subtotal)]
    (if (= total (+ subtotal 20))
      {"total" total}
      (fail "order tax invariant violated: expected subtotal plus 20"))))
