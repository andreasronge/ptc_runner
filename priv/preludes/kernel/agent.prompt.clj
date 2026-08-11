(ns agent.prompt "Domain-blind system-prompt policy for agent.core." {:visibility :discoverable})

(defn initial-state [cfg]
  {:revision 0
   ;; The prompt renders the API of the mission this agent evaluates into, so
   ;; two agents in one run can be given two different mission APIs without a
   ;; second mechanism.
   :mission (or (get cfg "mission") "default")
   :turns-remaining (get cfg "max_turns")
   :max-observation-chars (get cfg "max_observation_chars")
   :max-program-chars (get cfg "max_program_chars")})

(defn- inline-json [value]
  (let [encoded (json/generate-string value)
        line-separator (json/parse-string "\"\\u2028\"")
        paragraph-separator (json/parse-string "\"\\u2029\"")]
    (replace (replace encoded line-separator "\\u2028") paragraph-separator "\\u2029")))

(defn- escaped-text [value]
  (if (string? value)
    (let [encoded (inline-json value)]
      (if (>= (count encoded) 2)
        (subs encoded 1 (dec (count encoded)))
        ""))
    ""))

(defn- render-name [name]
  (if (and (string? name) (re-matches #"[A-Za-z_][A-Za-z0-9_-]*" name))
    name
    (inline-json name)))

(defn- render-field [field]
  (str (render-name (get field "name"))
       (if (false? (get field "required")) "?" "")
       " "
       (render-type (get field "type"))))

(defn- render-type [node]
  (if (map? node)
    (let [kind (get node "kind")
          base
          (case kind
            "string" ":string"
            "integer" ":int"
            "number" ":float"
            "boolean" ":bool"
            "keyword" ":keyword"
            "datetime" ":datetime"
            "nil" "nil"
            "any" ":any"
            "array" (str "[" (render-type (get node "items")) "]")
            "object" (str "{" (join ", " (map render-field (get node "fields" []))) "}")
            ":any")]
      (str base (if (and (true? (get node "nullable")) (not= kind "nil")) "?" "")))
    ":any"))

(defn- render-parameter [parameter]
  (str (render-name (get parameter "name")) " " (render-type (get parameter "type"))))

(defn- render-contract [entry]
  (let [contract (get entry "contract")]
    (if (map? contract)
      (if (= "value" (get entry "kind"))
        (render-type (get contract "value"))
        (let [parameters (get contract "parameters" [])
              returns (get contract "returns")]
          (str "(" (join ", " (map render-parameter parameters)) ")"
               (if (map? returns) (str " -> " (render-type returns)) ""))))
      nil)))

(defn- child-path [path name]
  (str path "[" (inline-json name) "]"))

(defn- own-constraints [node path]
  (filterv
    (fn [line] (not (nil? line)))
    [(when (contains? node "enum")
       (str path " is one of " (inline-json (get node "enum"))))
     (when (contains? node "const")
       (str path " must equal " (inline-json (get node "const"))))
     (when (contains? node "minimum")
       (str path " >= " (get node "minimum")))
     (when (contains? node "maximum")
       (str path " <= " (get node "maximum")))
     (when (contains? node "min_length")
       (str path " length >= " (get node "min_length")))
     (when (contains? node "max_length")
       (str path " length <= " (get node "max_length")))
     (when (contains? node "min_items")
       (str path " item count >= " (get node "min_items")))
     (when (contains? node "max_items")
       (str path " item count <= " (get node "max_items")))
     (when (and (= "object" (get node "kind")) (true? (get node "closed")))
       (str path " has no additional fields"))]))

(defn- constraint-lines [node path]
  (if (map? node)
    (let [own (own-constraints node path)
          kind (get node "kind")]
      (case kind
        "object"
        (concat
          own
          (mapcat
            (fn [field]
              (constraint-lines
                (get field "type")
                (child-path path (get field "name"))))
            (get node "fields" [])))

        "array"
        (concat own (constraint-lines (get node "items") (str path "[]")))

        own))
    []))

(defn- entry-constraints [entry]
  (let [contract (get entry "contract")]
    (if (map? contract)
      (if (= "value" (get entry "kind"))
        (constraint-lines (get contract "value") "value")
        (concat
          (mapcat
            (fn [parameter]
              (constraint-lines (get parameter "type") (get parameter "name")))
            (get contract "parameters" []))
          (constraint-lines (get contract "returns") "return")))
      [])))

(defn- node-doc [node]
  (let [title (get node "title")
        description (get node "description")
        title? (and (string? title) (not (blank? title)))
        description? (and (string? description) (not (blank? description)))]
    (cond
      (and title? description?) (str (escaped-text title) " — " (escaped-text description))
      title? (escaped-text title)
      description? (escaped-text description)
      :else nil)))

(defn- documentation-lines [node path]
  (if (map? node)
    (let [own-doc (node-doc node)
          own (if own-doc [(str path ": " own-doc)] [])
          kind (get node "kind")]
      (case kind
        "object"
        (concat
          own
          (mapcat
            (fn [field]
              (documentation-lines
                (get field "type")
                (child-path path (get field "name"))))
            (get node "fields" [])))

        "array"
        (concat own (documentation-lines (get node "items") (str path "[]")))

        own))
    []))

(defn- entry-documentation [entry]
  (let [contract (get entry "contract")]
    (if (map? contract)
      (if (= "value" (get entry "kind"))
        (documentation-lines (get contract "value") "value")
        (concat
          (mapcat
            (fn [parameter]
              (documentation-lines (get parameter "type") (get parameter "name")))
            (get contract "parameters" []))
          (documentation-lines (get contract "returns") "return")))
      [])))

(defn- render-entry [entry]
  (let [type-line (render-contract entry)
        constraints (entry-constraints entry)
        schema-docs (entry-documentation entry)
        effect (get entry "effect")
        docs (get entry "docs")]
    (str "- " (if (= "value" (get entry "kind")) "Value" "Call")
         ": " (get entry "form") "\n"
         (if type-line (str "  Type: " type-line "\n") "")
         (if (seq constraints)
           (str "  Constraints: " (join "; " constraints) "\n")
           "")
         (if (seq schema-docs)
           (str "  Schema docs: " (join "; " schema-docs) "\n")
           "")
         (if (and (string? effect) (not= effect "unknown"))
           (str "  Effect: " effect "\n")
           "")
         (if (and (string? docs) (not (blank? docs)))
           (str "  Docs: " (escaped-text docs) "\n")
           ""))))

(defn- direct-tool-entry? [entry]
  (starts-with? (get entry "form" "") "(tool/"))

(defn- prelude-call-entry? [entry]
  (and (= "call" (get entry "kind"))
       (not (direct-tool-entry? entry))))

(defn- prompt-entries [entries]
  (if (some prelude-call-entry? entries)
    (filterv #(not (direct-tool-entry? %)) entries)
    entries))

;; A facade's namespace docstring states the contract its functions share. It is
;; rendered once, above the calls, so the task prompt does not have to restate
;; it and drift from it.
(defn- render-namespaces [namespaces]
  (if (seq namespaces)
    (str "API notes\n"
         (join "\n"
               (map #(str "- " (get % "namespace") ": " (get % "doc")) namespaces))
         "\n\n")
    ""))

(defn- render-api [namespaces entries]
  (if (seq entries)
    (str "Available API\n"
         (render-namespaces namespaces)
         (if (some #(starts-with? (get % "form") "(tool/") entries)
           (str "Calls beginning with tool/ take exactly one argument map and return a result "
                "envelope. Check :status; when it is :ok, the displayed return type describes "
                "the :value field.\n")
           "")
         "In map types, field? means the field may be omitted; type? means nil is allowed.\n\n"
         (join "\n" (map render-entry entries))
         "\n")
    "Available API\n"))

(defn render [state]
  (if (map? state)
    (let [context (json/parse-string
                    (kernel/mission-model-context-in (or (get state :mission) "default")))]
      (if (and (map? context) (= 2 (get context "schema_version")))
        (str "PTC_AGENT_PROMPT_V1\n\n"
             "Instructions\n"
             "Use the run_ptc_lisp tool exactly once per turn with one program string.\n"
             "Ordinary expression results are intermediate observations and continue to another turn.\n"
             "The last expression's value is retained as *1; end a program with nil when you only meant to define something, so a large intermediate is not carried forward.\n"
             "Definitions created by successful programs persist and can be reused by later programs in this run.\n"
             "Failed evaluations roll back every definition created by that failed program.\n"
             "Use (return value) only when the task is complete; (return value) completes successfully.\n"
             "Use (fail value) only when the task cannot be completed; (fail value) aborts the run.\n"
             "Generated programs run only against the advertised mission API below.\n"
             "Do not repeat irreversible capability effects merely to reconstruct state.\n"
             (if (= 1 (get state :turns-remaining))
               "FINAL TURN: the next program must call (return value) or (fail value).\n"
               "")
             "Do not answer in prose.\n\n"
             "PTC-Lisp\n"
             "- PTC-Lisp is a bounded Clojure-like language.\n"
             "- Use let, fn, def/defn, if, loop/recur, map/filter/reduce, and collection helpers.\n"
             "- Also available: cond/case, ->/->>, for/doseq, string, set, regex, math, date/time, and json helpers.\n"
             "- Decoded JSON maps use string keys; read them with get/get-in.\n"
             "- Explore first, return last. Use (println ...) only for concise diagnostics; output previews are bounded.\n"
             "- Successful def and defn bindings remain callable in later turns; failed turns publish none of their candidate bindings.\n"
             "- Value references are values; call only function references.\n"
             "- The API below is the prompt-visible subset: (dir) lists namespaces, (dir \"ns\") its exports, (apropos \"term\") searches, (doc \"ns/name\") prints documentation, (export-meta \"ns/name\") returns it as data. Exports found this way are callable.\n"
             "- Call granted capabilities only with the exact tool/... forms shown below.\n"
             "- Fixed namespaces: clojure.core/core, clojure.string/str/string, clojure.set/set, clojure.walk/walk, regex, Math, System, Boolean, numeric/date/time namespaces, data, tool, and json.\n"
             "- No ns/require/refer/import, user-defined macros, eval/read-string, host file I/O, or general Java interop.\n\n"
             "Examples\n"
             "Turn 1: (defn add-one [x] (+ x 1))\n"
             "Turn 2: (return (add-one 41))\n"
             "(let [rows (get data/input \"rows\") active (filter #(true? (get % \"active\")) rows)] (return (mapv #(get % \"id\") active)))\n"
             "(let [response (tool/exact-name {\"query\" \"value\"})] (if (= :ok (get response :status)) (return (get response :value)) (fail response)))\n\n"
             (render-api
               (get context "namespaces" [])
               (prompt-entries
                 (sort-by #(get % "form") (get context "entries" [])))))
        nil))
    nil))

(defn transition [state event]
  (if (and (map? state) (map? event))
    (assoc state
           :revision (inc (get state :revision 0))
           :turns-remaining (get event :turns-remaining))
    nil))
