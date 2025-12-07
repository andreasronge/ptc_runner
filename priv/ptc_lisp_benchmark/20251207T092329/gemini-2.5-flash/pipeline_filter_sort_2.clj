;; Scenario: pipeline_filter_sort
;; Level: 2
;; Iteration: 2
;; Valid: true
;; Errors: []
;; Duration: 2023ms

(->> ctx/input
     (filter (where :salary > 50000))
     (sort-by :salary >)
     (take 5))
