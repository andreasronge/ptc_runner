(ns delivery.label "Optional parcel-label formatting." {:visibility :discoverable})

(defn summary
  "Format a parcel weight for a human-readable label."
  {:signature "(grams :int) -> :string"}
  [grams]
  (str grams "g parcel"))
