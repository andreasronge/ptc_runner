;; Scenario: simple_count
;; Level: 1
;; Iteration: 3
;; Valid: true
;; Errors: []
;; Duration: 2853ms

(count (filter (where :active = true) ctx/input))
