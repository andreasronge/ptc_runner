(ns delivery "Delivery quotation API." {:visibility :prompt})

(defn quote
  "Return a checked local-delivery quote for one parcel."
  {:signature "(parcel :map) -> {band :string, fee :int}"}
  [parcel]
  (let [grams (get parcel "grams")
        destination (get parcel "destination")
        expected-band (if (<= grams 1000) "standard" "oversize")
        expected-fee (if (= expected-band "standard") 9 17)
        quote (delivery.engine/local-quote grams)]
    (if (and (= destination "local")
             (= expected-band (get quote "band"))
             (= expected-fee (get quote "fee")))
      quote
      (fail "local delivery quote invariant failed"))))
