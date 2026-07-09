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

(defn- optional-detail
  [prefix value]
  (if (empty? value) "" (str prefix value)))

(defn- symbol-label
  [fact]
  (if (= (fact "kind") "function")
    (str (fact "ref") " [" (str/join " " (fact "params")) "]")
    (fact "ref")))

(defn- symbol-detail
  [fact]
  (if (= (fact "kind") "function")
    (str "function"
         (optional-detail " [" (fact "effect"))
         (if (empty? (fact "effect")) "" "]")
         ", use: " (fact "usage")
         (optional-detail " - " (fact "doc")))
    (str "value"
         (optional-detail " " (fact "type"))
         (optional-detail ", sample: " (fact "sample"))
         ", use: " (fact "usage")
         (optional-detail " - " (fact "doc")))))

(defn- symbol-line
  [fact]
  (str (symbol-label fact) " ; " (symbol-detail fact)))

(defn render-symbols
  "Render sanitized symbol facts supplied by the host."
  [cfg]
  (let [facts (cfg "symbol_facts")]
    (if (empty? facts)
      (cfg "symbol_inventory")
      (str ";; === available symbols ===\n"
           "Use value symbols directly. Call only function symbols.\n"
           (str/join "\n" (map symbol-line facts))))))

(defn task-message
  "Render the initial user task message."
  [mission cfg]
  (let [symbols (render-symbols cfg)]
    {"role" "user"
     "content" (str (if (empty? symbols) "" (str symbols "\n\n"))
                    "<mission>\n" (mission "task") "\n</mission>")}))
