(ns delivery.band "Parcel-weight band classification." {:visibility :discoverable})

(defn classify
  "Classify a parcel as standard at or below 1000 grams, otherwise oversize."
  {:signature "(grams :int) -> :string"}
  [grams]
  (if (<= grams 1000)
    "oversize"
    "standard"))
