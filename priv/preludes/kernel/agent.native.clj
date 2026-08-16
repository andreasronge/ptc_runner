(ns agent.native "Strict run_ptc_lisp model-action protocol." {:visibility :prompt})

(defn tool-schema
  "Returns the strict provider-neutral run_ptc_lisp tool schema."
  []
  {"type" "function"
   "function"
   {"name" "run_ptc_lisp"
    "description" "Run one PTC-Lisp program. Ordinary success continues; return completes and fail aborts."
    "parameters"
    {"type" "object"
     "additionalProperties" false
     "required" ["program"]
     "properties" {"program" {"type" "string"}}}}})

(defn- protocol-error [reason]
  {:kind :protocol-error :reason reason})

(defn- call-name [call]
  (or (get call "name")
      (get-in call ["function" "name"])))

(defn- call-arguments [call]
  (let [arguments (or (get call "args")
                      (get call "arguments")
                      (get-in call ["function" "arguments"]))]
    (if (string? arguments)
      (json/parse-string arguments)
      arguments)))

(defn normalize
  "Normalizes one provider response into a tool call, provider error, or protocol error."
  [response max-program-chars]
  (let [max-program-chars (if (and (integer? max-program-chars)
                                   (pos? max-program-chars)
                                   (<= max-program-chars 1000000))
                            max-program-chars
                            64000)]
  (cond
    (and (map? response) (= :error (get response :status)))
    {:kind :provider-error :error response}

    (not (map? response))
    (protocol-error :invalid-response)

    :else
    ;; Narration alongside a call is the native shape of a tool-calling turn:
    ;; `content` and `tool_calls` are sibling fields, and instruction tuning
    ;; rewards saying what you are about to do. Rejecting it discarded correct
    ;; programs. Prose only violates the protocol when it arrives *instead of*
    ;; a call, which is the case this rule exists to catch.
    (let [calls (get response "tool_calls")
          prose (get response "content")
          narrating? (and (string? prose) (not (blank? prose)))]
      (cond
        (not (sequential? calls))
        (if narrating?
          (protocol-error :assistant-text-without-tool-call)
          (protocol-error :missing-tool-call))

        (not= 1 (count calls)) (protocol-error :multiple-or-missing-tool-calls)
        :else
        (let [call (first calls)
              arguments (call-arguments call)
              program (if (map? arguments) (get arguments "program") nil)]
          (cond
            (not= "run_ptc_lisp" (call-name call)) (protocol-error :wrong-tool-name)
            (or (not (string? (get call "id")))
                (blank? (get call "id"))) (protocol-error :invalid-tool-call-id)
            (not (map? arguments)) (protocol-error :invalid-json-arguments)
            (or (not= 1 (count arguments))
                (not (contains? arguments "program"))) (protocol-error :extra-or-missing-arguments)
            (not (string? program)) (protocol-error :program-not-string)
            (blank? program) (protocol-error :program-empty)
            (> (count program) max-program-chars) (protocol-error :program-too-large)
            :else {:kind :tool-call
                   :program program
                   :rationale (when narrating? prose)
                   :tool-call-id (get call "id")
                   :public-tool-call call})))))))
