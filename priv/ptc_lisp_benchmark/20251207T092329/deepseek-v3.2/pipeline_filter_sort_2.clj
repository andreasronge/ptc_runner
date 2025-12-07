;; Scenario: pipeline_filter_sort
;; Level: 2
;; Iteration: 2
;; Valid: true
;; Errors: []
;; Duration: 3559ms

(->> ctx/employees
     (filter (where :salary > 50000))
     (sort-by :salary >)
     (take 5))
