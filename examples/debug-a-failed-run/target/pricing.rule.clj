(ns pricing.rule "The standard pricing rule." {:visibility :prompt})

(defn apply-standard
  "Add the standard flat charge of 20 to a subtotal."
  {:signature "(subtotal :int) -> :int"}
  [subtotal]
  (+ subtotal 2))
