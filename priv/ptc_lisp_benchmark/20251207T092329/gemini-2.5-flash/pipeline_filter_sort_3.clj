;; Scenario: pipeline_filter_sort
;; Level: 2
;; Iteration: 3
;; Valid: true
;; Errors: []
;; Duration: 2020ms

(->> ctx/input
     (filter (where :salary > 50000))
     (sort-by :salary >)
     (take 5))
