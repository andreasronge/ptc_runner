(ns example.replay)

(defn run [_input]
  (return
    (cap/unwrap!
      (tool/llm-request
        {"system" "Reply with the frozen answer."
         "messages" [{"role" "user" "content" "What value is frozen?"}]}))))
