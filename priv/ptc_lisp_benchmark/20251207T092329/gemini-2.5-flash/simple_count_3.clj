;; Scenario: simple_count
;; Level: 1
;; Iteration: 3
;; Valid: true
;; Errors: []
;; Duration: 1841ms

(->> ctx/input
     (filter (where :active))
     (count))
