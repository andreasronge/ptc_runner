(ns pricing.base "The amount the standard rule applies to." {:visibility :prompt})

(defn amount
  "Return the amount the standard charge applies to."
  {:signature "(subtotal :int) -> :int"}
  [subtotal]
  subtotal)
