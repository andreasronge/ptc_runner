;; Scenario: simple_count
;; Level: 1
;; Iteration: 2
;; Valid: true
;; Errors: []
;; Duration: 1931ms

(->> ctx/input
     (filter (where :active))
     count)
