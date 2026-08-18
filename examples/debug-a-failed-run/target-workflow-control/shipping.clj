(ns shipping
  "Shipment scheduling operations."
  {:visibility :prompt})

(defn schedule
  "Schedule exactly the supplied reservation and preserve its identifier in the result."
  {:signature "(request :map) -> :map"}
  [request]
  {"reservation_id" (get request "reservation_id")
   "destination" (get request "destination")
   "status" "scheduled"})
