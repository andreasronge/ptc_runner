(ns orders "Order pricing API." {:visibility :prompt})

(defn place
  "Return the combined base and tax charge for an order."
  {:signature "(subtotal :int) -> :map"}
  [subtotal]
  {"total" (+ (pricing.base/amount subtotal) (pricing.tax/amount subtotal))})
