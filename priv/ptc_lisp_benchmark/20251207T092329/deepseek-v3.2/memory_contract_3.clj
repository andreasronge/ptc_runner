;; Scenario: memory_contract
;; Level: 4
;; Iteration: 3
;; Valid: true
;; Errors: []
;; Duration: 2962ms

(let [orders (call "get-orders" {})
      high-value-orders (filter (where :amount > 1000) orders)]
  {:high_value_orders high-value-orders
   :result (count high-value-orders)})
