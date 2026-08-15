(ns delivery.tariff "Local-delivery fees by parcel band." {:visibility :discoverable})

(defn local-fee
  "Return the local-delivery fee for a parcel band."
  {:signature "(band :string) -> :int"}
  [band]
  (case band
    "standard" 9
    "oversize" 17
    (fail "unknown parcel band")))
