(ns pricing.rule "The standard pricing rule." {:visibility :prompt})

(defn apply-standard
  "Add the standard charge to a subtotal."
  {:signature "(subtotal :int) -> :int"}
  [subtotal]
  (+ subtotal 2))
