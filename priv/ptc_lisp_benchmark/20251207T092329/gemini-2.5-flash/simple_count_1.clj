;; Scenario: simple_count
;; Level: 1
;; Iteration: 1
;; Valid: true
;; Errors: []
;; Duration: 3645ms

(count (filter (where :active) ctx/input))
