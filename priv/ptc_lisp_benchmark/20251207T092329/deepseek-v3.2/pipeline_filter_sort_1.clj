;; Scenario: pipeline_filter_sort
;; Level: 2
;; Iteration: 1
;; Valid: true
;; Errors: []
;; Duration: 4567ms

(let [all-employees ctx/employees
      filtered (filter (where :salary > 50000) all-employees)
      sorted (sort-by :salary > filtered)]
  (take 5 sorted))
