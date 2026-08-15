(ns pricing.rule "Internal standard-pricing rule." {:visibility :discoverable})

(defn apply-standard
  "Apply the configured standard addition to a subtotal."
  {:signature "(subtotal :int) -> :int"}
  [subtotal]
  (+ subtotal 2))
