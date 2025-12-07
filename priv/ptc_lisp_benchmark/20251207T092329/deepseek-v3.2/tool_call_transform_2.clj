;; Scenario: tool_call_transform
;; Level: 4
;; Iteration: 2
;; Valid: true
;; Errors: []
;; Duration: 3582ms

(let [users (call "get-users" {})
      premium-users (filter (where :tier = "premium") users)]
  (pluck :email premium-users))
