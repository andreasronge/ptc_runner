;; Scenario: aggregate_sum
;; Level: 2
;; Iteration: 3
;; Valid: true
;; Errors: []
;; Duration: 2253ms

(->> ctx/orders
     (filter (where :status = "completed"))
     (sum-by :amount))
