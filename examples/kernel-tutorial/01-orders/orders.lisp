(ns tutorial.orders "Deterministic order aggregation." {:visibility :prompt})

(defn summarize [input]
  (let [orders (get input "orders")
        paid (filter #(= "paid" (get % "status")) orders)]
    (return
      {"order_count" (count orders)
       "paid_count" (count paid)
       "paid_total" (reduce + 0 (map #(get % "total") paid))
       "pending_ids" (mapv #(get % "id")
                           (filter #(= "pending" (get % "status")) orders))})))
