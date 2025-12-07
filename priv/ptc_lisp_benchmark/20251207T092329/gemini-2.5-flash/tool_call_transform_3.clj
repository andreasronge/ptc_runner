;; Scenario: tool_call_transform
;; Level: 4
;; Iteration: 3
;; Valid: true
;; Errors: []
;; Duration: 2228ms

(->> (call "get-users" {})
     (filter (where :tier = "premium"))
     (pluck :email))
