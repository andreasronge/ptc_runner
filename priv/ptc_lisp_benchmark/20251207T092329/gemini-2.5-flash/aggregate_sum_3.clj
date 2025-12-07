;; Scenario: aggregate_sum
;; Level: 2
;; Iteration: 3
;; Valid: true
;; Errors: []
;; Duration: 3484ms

(->> ctx/input
     (filter (where :status = "completed"))
     (sum-by :amount))
