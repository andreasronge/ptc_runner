(ns main
  "Deterministic fulfillment workflow. It reserves inventory, then schedules that exact reservation for shipment."
  {:visibility :prompt})

(defn- reservation-source [input]
  (str "(return (inventory/reserve "
       (pr-str
         {"order_id" (get input "order_id")
          "item" (get input "item")})
       "))"))

(defn- shipment-source [input reservation]
  (str "(return (shipping/schedule "
       (pr-str
         {"reservation_id" (get input "order_id")
          "destination" (get input "destination")})
       "))"))

(defn run
  "Reserve the requested item and schedule the resulting reservation for shipment."
  {:signature "(input :map) -> :map"}
  [input]
  (let [reservation-evaluation
        (kernel/eval-source "inventory" (reservation-source input))
        reservation (get reservation-evaluation "value")
        shipment-evaluation
        (kernel/eval-source "shipping" (shipment-source input reservation))
        shipment (get shipment-evaluation "value")]
    (if (= (get shipment "reservation_id")
           (get reservation "reservation_id"))
      (return shipment)
      (fail {:kind "reservation-routing-mismatch"}))))
