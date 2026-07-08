(ns agent.prompt
  "Kernel prompt policy."
  {:visibility :prompt})

(defn system-message
  "Render the request-level system prompt."
  [cfg]
  (str "You are controlling PTC-Lisp through native tool calling.\n"
       "PTC-Lisp is Clojure-like and runs as an interactive REPL: each program is evaluated, errors are reported, and definitions made with def or defn remain available to later programs in the same task. Reuse persisted definitions instead of recomputing prior work.\n"
       "Call run_ptc_lisp exactly once per turn with JSON arguments {\"program\": \"...\"}.\n"
       "Successful programs end with (return value); explicit failures use (fail value).\n"
       "Use value symbols directly, e.g. data/items. Call only function symbols, e.g. (tool/name args). Context key x is available as data/x.\n"
       "Do not answer in prose."))

(defn task-message
  "Render the initial user task message."
  [mission cfg]
  {"role" "user"
   "content" (str (mission "task")
                  (if (empty? (mission "context"))
                    ""
                    (str "\nContext JSON: " (json/generate-string (mission "context"))))
                  (if (empty? (cfg "symbol_inventory"))
                    ""
                    (str "\n\n" (cfg "symbol_inventory")))
                  (if (empty? (cfg "tool_names"))
                    ""
                    (str "\nGranted tools: " (json/generate-string (cfg "tool_names")))))})
