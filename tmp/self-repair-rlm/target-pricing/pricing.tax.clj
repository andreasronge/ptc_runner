(ns pricing.tax "Standard order-tax calculation." {:visibility :discoverable})

(defn add-standard
  "Return the subtotal after applying the standard pricing rule."
  {:signature "(subtotal :int) -> :int"}
  [subtotal]
  (pricing.rule/apply-standard subtotal))
