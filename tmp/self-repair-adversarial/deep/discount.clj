(ns pricing.discount "Optional discount calculation." {:visibility :discoverable})

(defn preview
  "Preview a two-unit discount without applying it to an order."
  {:signature "(subtotal :int) -> :int"}
  [subtotal]
  (- subtotal 2))
