;; Scenario: tool_call_transform
;; Level: 4
;; Iteration: 1
;; Valid: true
;; Errors: []
;; Duration: 3299ms

(->> (call "get-users" {})
     (filter (where :tier = "premium"))
     (pluck :email))
