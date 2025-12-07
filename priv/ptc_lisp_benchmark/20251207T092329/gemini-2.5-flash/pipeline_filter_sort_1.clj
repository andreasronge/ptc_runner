;; Scenario: pipeline_filter_sort
;; Level: 2
;; Iteration: 1
;; Valid: true
;; Errors: []
;; Duration: 1706ms

(->> ctx/input
     (filter (where :salary > 50000))
     (sort-by :salary >)
     (take 5))
