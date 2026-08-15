(ns delivery.engine "Delivery quote calculation." {:visibility :discoverable})

(defn local-quote
  "Calculate the band and fee for a local parcel."
  {:signature "(grams :int) -> {band :string, fee :int}"}
  [grams]
  (let [band (delivery.band/classify grams)]
    {"band" band
     "fee" (delivery.tariff/local-fee band)}))
