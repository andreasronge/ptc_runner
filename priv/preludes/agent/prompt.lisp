(ns agent.prompt
  "Kernel prompt policy."
  {:visibility :prompt})

(defn system-message
  "Render the request-level system prompt."
  [cfg]
  (str "You are controlling PTC-Lisp through native tool calling.\n"
       "PTC-Lisp is Clojure-like and runs as an interactive REPL: each program is evaluated, errors are reported, and definitions made with def or defn remain available to later programs in the same task. Reuse persisted definitions instead of recomputing prior work.\n"
       "Call " (cfg "protocol_tool_name") " exactly once per turn with JSON arguments {\"program\": \"...\"}.\n"
       "Successful programs end with (return value); explicit failures use (fail value).\n"
       "Use value symbols directly, e.g. data/items. Call only function symbols, e.g. (tool/name args). Context key x is available as data/x.\n"
       "Do not answer in prose."))

(defn render-symbols
  "Select the bounded host-rendered symbol inventory."
  [cfg]
  (cfg "symbol_inventory"))

(defn task-message
  "Render the initial user task message."
  [mission cfg]
  (let [symbols (render-symbols cfg)]
    {"role" "user"
     "content" (str (if (empty? symbols) "" (str symbols "\n\n"))
                    "<mission>\n" (mission "task") "\n</mission>")}))
