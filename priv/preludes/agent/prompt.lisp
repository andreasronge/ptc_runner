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
       "Read context key x as data/x and call granted tools as (tool/name args) inside the program.\n"
       "Do not answer in prose."))

(defn task-message
  "Render the initial user task message."
  [mission cfg]
  {"role" "user"
   "content" (str (mission "task")
                  (if (empty? (mission "context"))
                    ""
                    (str "\nContext JSON: " (json/generate-string (mission "context"))))
                  (if (empty? (cfg "tool_names"))
                    ""
                    (str "\nGranted tools: " (json/generate-string (cfg "tool_names")))))})
