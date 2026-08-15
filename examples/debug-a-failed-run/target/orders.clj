(ns orders "Order pricing API." {:visibility :prompt})

(defn place
  "Return the payable total for one order."
  {:signature "(order :map) -> :map"}
  [order]
  {"total" (pricing.tax/add-standard (get order "subtotal"))})
