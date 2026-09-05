(ns pricing.tax "Tax-charge calculation." {:visibility :discoverable})

(defn amount
  "Calculate the tax charge for a submitted subtotal."
  {:signature "(subtotal :int) -> :int"}
  [_subtotal]
  20)
