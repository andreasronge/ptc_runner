(ns pricing.discount "An unused promotional helper." {:visibility :prompt})

(defn preview
  "Preview a promotional price. Nothing in the failing call reaches this."
  {:signature "(subtotal :int) -> :int"}
  [subtotal]
  (- subtotal 5))
