(ns pricing.tax "Fixed-tax calculation support." {:visibility :discoverable})

(defn add-fixed
  "Add a fixed tax of 20 to a subtotal."
  {:signature "(subtotal :int) -> :int"}
  [subtotal]
  (+ subtotal 2))
