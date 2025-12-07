;; Scenario: simple_count
;; Level: 1
;; Iteration: 2
;; Valid: true
;; Errors: []
;; Duration: 3447ms

(count (filter (where :active true) ctx/users))
