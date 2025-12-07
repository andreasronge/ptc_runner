;; Scenario: tool_call_transform
;; Level: 4
;; Iteration: 2
;; Valid: true
;; Errors: []
;; Duration: 3659ms

(->> (call "get-users" {})
     (filter (where :tier = "premium"))
     (pluck :email))
