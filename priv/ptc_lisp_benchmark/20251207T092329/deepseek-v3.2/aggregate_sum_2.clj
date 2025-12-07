;; Scenario: aggregate_sum
;; Level: 2
;; Iteration: 2
;; Valid: true
;; Errors: []
;; Duration: 4875ms

(let [completed-orders (filter (where :status = "completed") ctx/orders)
      total-amount (sum-by :amount completed-orders)]
  total-amount)
