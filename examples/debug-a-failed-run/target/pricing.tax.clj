(ns pricing.tax "Standard tax application." {:visibility :prompt})

(defn add-standard
  "Apply the standard rule to a subtotal."
  {:signature "(subtotal :int) -> :int"}
  [subtotal]
  (pricing.rule/apply-standard subtotal))
