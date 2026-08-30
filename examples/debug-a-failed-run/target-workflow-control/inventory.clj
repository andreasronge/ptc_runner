(ns inventory
  "Inventory reservation operations."
  {:visibility :prompt})

(defn reserve
  "Reserve one item for an order and return the reservation identifier downstream operations must use."
  {:signature "(request :map) -> :map"}
  [request]
  {"reservation_id" (str "reservation:" (get request "order_id"))
   "item" (get request "item")})
