;; Scenario: tool_call_transform
;; Level: 4
;; Iteration: 1
;; Valid: true
;; Errors: []
;; Duration: 5243ms

(let [users (call "get-users" {})
      premium-users (filter (where :tier = "premium") users)]
  (pluck :email premium-users))
