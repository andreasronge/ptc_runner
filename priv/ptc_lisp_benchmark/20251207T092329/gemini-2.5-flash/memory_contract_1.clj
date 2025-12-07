;; Scenario: memory_contract
;; Level: 4
;; Iteration: 1
;; Valid: true
;; Errors: []
;; Duration: 2000ms

(let [all-orders (call "get-orders" {})
      high-value-orders (filter (where :amount > 1000) all-orders)]
  {:high_value_orders high-value-orders
   :result (count high-value-orders)})
