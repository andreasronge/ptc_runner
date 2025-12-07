;; Scenario: aggregate_sum
;; Level: 2
;; Iteration: 1
;; Valid: true
;; Errors: []
;; Duration: 3255ms

(let [completed (filter (where :status = "completed") ctx/orders)
      total (sum-by :amount completed)]
  total)
