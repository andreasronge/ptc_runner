;; Scenario: simple_count
;; Level: 1
;; Iteration: 1
;; Valid: true
;; Errors: []
;; Duration: 6766ms

(count (filter (where :active true) ctx/users))
