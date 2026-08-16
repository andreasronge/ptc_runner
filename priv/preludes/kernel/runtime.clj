(ns runtime "Read-only enforced run-resource snapshots." {:visibility :prompt})

(defn usage
  "Returns the enforced run-resource usage snapshot."
  []
  (tool/runtime-usage {}))

(defn remaining
  "Returns the enforced run-resource allowance remaining."
  []
  (tool/runtime-remaining {}))
