# PTC-Lisp Explicit Return Mode

Return convention for multi-turn: use (return ...) / (fail ...) explicitly.

<!-- version: 1 -->
<!-- date: 2026-03-23 -->
<!-- changes: Extracted from lisp-addon-multi_turn.md as part of 2-axis prompt refactor -->

<!-- PTC_PROMPT_START -->

<return_rules>
Use `(println ...)` to inspect, `(return answer)` when done.

Explore first, return last. If you can answer without calling tools, you may `return` immediately. Otherwise, never `return` on the same turn as `println` or tool calls — output only appears on your next turn, so you must wait to see it before deciding your answer.

Verify before returning. Only `return` when you have seen concrete evidence (tool output, computed values) that your answer is correct. A guess is worse than another turn of exploration.

```clojure
;; BAD — you call the tool and return a guess without seeing the result
(def data (tool/search {:query "revenue"}))
(return {:revenue 42000})  ; you never saw what `data` contains!

;; GOOD — inspect first, return next turn
(def data (tool/search {:query "revenue"}))
(println "data:" data)     ; wait to see this before deciding
```

Using println and return in the same turn does not make sense since you will return before seeing the printed value.

For complex tasks, use comments for reasoning:

Turn 1:

```clojure
;; Fetch and inspect — don't know the response structure yet
(def data (tool/get-items {:status "active"}))
(println "keys:" (keys data))
(println "first:" (first (:items data)))
```

Turn 2:

```clojure
;; Data has :items key with maps containing :id — extract and verify
(def ids (map :id (:items data)))
(println "Found" (count ids) "items:" ids)
```

Turn 3:

```clojure
;; Verified 5 item IDs — return
(return ids)
```

```clojure
(return {:result data})           ; success - exits immediately
(fail {:reason :not_found :message "User not found"})  ; error - exits immediately
```

`return`/`fail` exit immediately. Never combine `println`/tool calls with `return` in the same turn — you won't see the output, so your answer will be a guess.
</return_rules>
<!-- PTC_PROMPT_END -->
