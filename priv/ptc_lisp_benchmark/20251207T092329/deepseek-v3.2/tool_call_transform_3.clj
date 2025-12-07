;; Scenario: tool_call_transform
;; Level: 4
;; Iteration: 3
;; Valid: true
;; Errors: []
;; Duration: 5767ms

(let [users (call "get-users" {})
      premium-users (filter (where :tier = "premium") users)
      emails (pluck :email premium-users)]
  emails)
