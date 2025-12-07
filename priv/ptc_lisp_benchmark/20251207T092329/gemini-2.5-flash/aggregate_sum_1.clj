;; Scenario: aggregate_sum
;; Level: 2
;; Iteration: 1
;; Valid: true
;; Errors: []
;; Duration: 1756ms

(->> ctx/input
     (filter (where :status = "completed"))
     (sum-by :amount))
