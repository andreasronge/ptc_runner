(ns agent.prompt "Domain-blind system-prompt policy for agent.core." {:visibility :discoverable})

(defn initial-state
  "Creates the initial domain-blind prompt-policy state from agent configuration."
  [cfg]
  {:revision 0
   ;; The prompt renders the API of the mission this agent evaluates into, so
   ;; two agents in one run can be given two different mission APIs without a
   ;; second mechanism.
   :mission (or (get cfg "mission") "default")
   :turns-remaining (get cfg "max_turns")
   :terminal-only? (true? (get cfg "terminal_only"))
   :max-observation-chars (get cfg "max_observation_chars")
   :max-program-chars (get cfg "max_program_chars")
   :result-contract (get cfg "result_contract")
   :result-contract-mode (get cfg "result_contract_mode")
   :phase-return-contract (get cfg "phase_return_contract")
   :phase-return-contract-name (get cfg "return_contract")})

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
            "tagged_union" (str "oneOf(" (join " | " (map #(render-type (get % "type")) (get node "variants" []))) ")")
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
     (when (contains? node "max_properties")
       (str path " field count <= " (get node "max_properties")))
     (when (and (= "string" (get node "kind")) (= "sha256" (get node "format")))
       (str path " has sha256 format"))
     (when (and (= "object" (get node "kind")) (true? (get node "closed")))
       (str path " has no additional fields"))]))

(defn- variant-path [path variant]
  (let [discriminator (get variant "discriminator")]
    (str path " when " (inline-json (get discriminator "name")) "="
         (inline-json (get discriminator "literal")))))

(defn- constraint-lines [node path]
  (if (map? node)
    (let [own (own-constraints node path)
          kind (get node "kind")]
      (case kind
        "object"
        (concat
          own
          (when (map? (get node "property_names"))
            (constraint-lines (get node "property_names") (str path " field-name")))
          (mapcat
            (fn [field]
              (constraint-lines
                (get field "type")
                (child-path path (get field "name"))))
            (get node "fields" [])))

        "array"
        (concat own (constraint-lines (get node "items") (str path "[]")))

        "tagged_union"
        (concat own
                (mapcat #(constraint-lines (get % "type") (variant-path path %))
                        (get node "variants" [])))

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
          (when (map? (get node "property_names"))
            (documentation-lines (get node "property_names") (str path " field-name")))
          (mapcat
            (fn [field]
              (documentation-lines
                (get field "type")
                (child-path path (get field "name"))))
            (get node "fields" [])))

        "array"
        (concat own (documentation-lines (get node "items") (str path "[]")))

        "tagged_union"
        (concat own
                (mapcat #(documentation-lines (get % "type") (variant-path path %))
                        (get node "variants" [])))

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
    "Available API\n- No mission-specific data, functions, or tools are available.\n"))

(defn- render-result-contract [state]
  (let [contract (get state :result-contract)
        mode (get state :result-contract-mode)]
    (if (and (map? contract) (or (= mode :identity) (= mode :ok-envelope)))
      (str "\nApplication result contract\n"
           (if (= mode :ok-envelope)
             "The host validates {\"ok\":true,\"value\":value}. Return only value; do not construct or return that envelope yourself.\n"
             "The host validates the exact value passed to (return value).\n")
           "Type: " (render-type contract) "\n"
           (let [constraints (constraint-lines contract "result")]
             (if (seq constraints) (str "Constraints: " (join "; " constraints) "\n") ""))
           (let [docs (documentation-lines contract "result")]
             (if (seq docs) (str "Schema docs: " (join "; " docs) "\n") "")))
      "")))

(defn- render-phase-return-contract [state]
  (let [contract (get state :phase-return-contract)
        name (get state :phase-return-contract-name)]
    (if (and (map? contract) (string? name))
      (str "\nCurrent phase return contract (" name ")\n"
           "A valid explicit (return value) is required to transition to the next phase.\n"
           "Type: " (render-type contract) "\n"
           (let [constraints (constraint-lines contract "phase-return")]
             (if (seq constraints) (str "Constraints: " (join "; " constraints) "\n") ""))
           (let [docs (documentation-lines contract "phase-return")]
             (if (seq docs) (str "Schema docs: " (join "; " docs) "\n") "")))
      "")))

(defn render
  "Renders the system prompt, or the capability error envelope that prevented it."
  [state]
  (if (map? state)
    (let [response (kernel/mission-model-context (or (get state :mission) "default"))]
      ;; A refused capability is the one failure here that carries a cause the
      ;; caller can act on -- a manifest that declares no mission of that name
      ;; answers `unknown_mission`. Collapsing it into nil is what left the run
      ;; reporting only that its prompt was invalid.
      (if (map? response)
        response
        (let [context (json/parse-string response)]
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
                 "The task and each continuation message state how many programs remain; use that budget to pace exploration.\n"
                 "When a budget notice says FINAL TURN, the next program must call (return value) or (fail value).\n"
                 "Do not answer in prose.\n\n"
                 "PTC-Lisp\n"
                 "- PTC-Lisp is a bounded Clojure-like language.\n"
                 "- Use let, fn, def/defn, if, loop/recur, map/filter/reduce, and collection helpers.\n"
                 "- Also available: cond/case, ->/->>, for/doseq, string, set, regex, math, date/time, and json helpers.\n"
                 "- Built-ins include collections, strings, regex, math, numeric parsing, and date/time, including a bounded Java-compatible API.\n"
                 "- Decoded JSON maps use string keys; read them with get/get-in.\n"
                 (if (true? (get state :terminal-only?))
                   "- TERMINAL-ONLY PHASE: send exactly one top-level (return value) or (fail value) form. Introspection, definitions, and intermediate evaluation are rejected before execution.\n"
                   "- Explore first, return last. Use (println ...) only for concise diagnostics; output previews are bounded.\n")
                 "- Successful def and defn bindings remain callable in later turns; failed turns publish none of their candidate bindings.\n"
                 "- Value references are values; call only function references.\n"
                 "- The Available API section below is complete for mission data, prompt-visible mission functions, and granted tools.\n"
                 "- Use (apropos \"term\") to search visible mission prelude exports plus fixed built-ins and the bounded Java surface; use (doc \"name\") to print their documentation. (dir) lists attached prelude namespaces, (dir \"ns\") their exports, (export-meta \"ns/name\") returns attached export metadata as data, and (source ns/name) prints an attached prelude definition when available. None enumerate data references or direct tool capabilities.\n"
                 "- Call granted capabilities only with the exact tool/... forms shown below.\n"
                 "- Fixed namespaces: clojure.core/core, clojure.string/str/string, clojure.set/set, clojure.walk/walk, regex, Math, System, Boolean, numeric/date/time namespaces, data, tool, and json.\n"
                 "- No ns/require/refer/import, user-defined macros, eval/read-string, or host file I/O.\n\n"
                 "Examples\n"
                 "Turn 1: (defn add-one [x] (+ x 1))\n"
                 "Turn 2: (return (add-one 41))\n"
                 "(let [response (tool/exact-name {\"query\" \"value\"})] (if (= :ok (get response :status)) (return (get response :value)) (fail response)))\n\n"
                 (render-api
                   (get context "namespaces" [])
                   (prompt-entries
                     (sort-by #(get % "form") (get context "entries" []))))
                 (render-result-contract state)
                 (render-phase-return-contract state))
            nil))))
    nil))

(defn transition
  "Advances prompt-policy state after one agent-loop event."
  [state event]
  (if (and (map? state) (map? event))
    (assoc state
           :revision (inc (get state :revision 0))
           :turns-remaining (get event :turns-remaining))
    nil))
