(ns inventory "Reservation API." {:visibility :prompt})

(defn reserve
  "Return a reservation_id containing the reserved SKU."
  {:signature "(sku :string, quantity :int) -> {reservation_id :string}"}
  [sku quantity]
  {"reservation_id" sku})
