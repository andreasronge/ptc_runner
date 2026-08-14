(ns example.replay)

(defn run [_input]
  (return
    (llm/request
      {"system" "Reply with the frozen answer."
       "messages" [{"role" "user" "content" "What value is frozen?"}]})))
