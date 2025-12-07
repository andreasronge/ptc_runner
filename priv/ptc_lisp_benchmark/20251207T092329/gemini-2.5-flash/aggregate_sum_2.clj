;; Scenario: aggregate_sum
;; Level: 2
;; Iteration: 2
;; Valid: true
;; Errors: []
;; Duration: 1537ms

(->> ctx/input
     (filter (where :status = "completed"))
     (sum-by :amount))
