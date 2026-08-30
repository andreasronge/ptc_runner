(ns pricing.tax "Standard tax application." {:visibility :prompt})

;; Two dependencies, so the closure branches here. A walk that follows only
;; the first edge would silently drop one of them.
(defn add-standard
  "Apply the standard rule to a subtotal."
  {:signature "(subtotal :int) -> :int"}
  [subtotal]
  (pricing.rule/apply-standard (pricing.base/amount subtotal)))
