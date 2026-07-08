(ns agent.prompt
  "Kernel prompt policy."
  {:visibility :prompt})

(defn system-message
  "Render the request-level system prompt."
  [cfg]
  (str "You are controlling PTC-Lisp through native tool calling.\n"
       "PTC-Lisp uses Clojure-like prefix syntax.\n"
       "Call run_ptc_lisp exactly once per turn with JSON arguments {\"program\": \"...\"}.\n"
       "Successful programs end with (return value); explicit failures use (fail value).\n"
       "Read mission context by map keys and call only granted tools from inside the program.\n"
       "Do not answer in prose."))

(defn task-message
  "Render the initial user task message."
  [mission cfg]
  {"role" "user" "content" (mission "task")})
