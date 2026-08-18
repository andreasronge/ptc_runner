(ns pricing.base "Base-charge calculation." {:visibility :discoverable})

(defn amount
  "Calculate the base charge for a submitted subtotal."
  {:signature "(subtotal :int) -> :int"}
  [_subtotal]
  80)
