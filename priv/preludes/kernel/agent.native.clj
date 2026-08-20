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

(defn- bound-narration [prose]
  (let [max-chars 2000
        marker "… [truncated]"]
    (if (or (not (string? prose)) (blank? prose))
      nil
      (if (<= (count prose) max-chars)
        prose
        (str (subs prose 0 (- max-chars (count marker))) marker)))))

(defn- with-evidence [error prose call]
  (let [narration (bound-narration prose)
        error (if narration (assoc error :narration narration) error)]
    (if call
      (assoc error :offending-call call)
      error)))

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

(defn- named-token [value]
  (cond
    (keyword? value) (name value)
    (string? value) value
    :else nil))

(defn- hyphenated? [value expected]
  (let [token (named-token value)]
    (or (= token expected)
        (and (= expected "limit-exceeded") (= token "limit_exceeded"))
        (and (= expected "capability-quota") (= token "capability_quota"))
        (and (= expected "max-calls") (= token "max_calls")))))

(defn- max-calls-refusal? [response]
  (and (map? response)
       (let [details (get response :details)]
         (and (hyphenated? (get response :status) "error")
              (hyphenated? (get response :kind) "limit-exceeded")
              (hyphenated? (get response :reason) "capability-quota")
              (map? details)
              (hyphenated? (get details :limit) "max-calls")
              (string? (get details :alias))
              (integer? (get details :limit_value))
              (pos? (get details :limit_value))))))

(defn normalize
  "Normalizes one provider response into a tool call, provider error, max-calls refusal, or protocol error."
  [response max-program-chars]
  (let [max-program-chars (if (and (integer? max-program-chars)
                                   (pos? max-program-chars)
                                   (<= max-program-chars 1000000))
                            max-program-chars
                            64000)]
  (cond
    (max-calls-refusal? response)
    {:kind :max-calls :error response}

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
          (with-evidence (protocol-error :assistant-text-without-tool-call) prose nil)
          (with-evidence (protocol-error :missing-tool-call) prose nil))

        (not= 1 (count calls))
        (with-evidence (protocol-error :multiple-or-missing-tool-calls) prose nil)

        :else
        (let [call (first calls)
              arguments (call-arguments call)
              program (if (map? arguments) (get arguments "program") nil)]
          (cond
            (not= "run_ptc_lisp" (call-name call))
            (with-evidence (protocol-error :wrong-tool-name) prose call)

            (or (not (string? (get call "id")))
                (blank? (get call "id")))
            (with-evidence (protocol-error :invalid-tool-call-id) prose call)

            (not (map? arguments))
            (with-evidence (protocol-error :invalid-json-arguments) prose call)

            (or (not= 1 (count arguments))
                (not (contains? arguments "program")))
            (with-evidence (protocol-error :extra-or-missing-arguments) prose call)

            (not (string? program))
            (with-evidence (protocol-error :program-not-string) prose call)

            (blank? program)
            (with-evidence (protocol-error :program-empty) prose call)

            (> (count program) max-program-chars)
            (with-evidence
              (assoc (assoc (protocol-error :program-too-large)
                            :limit max-program-chars)
                     :size (count program))
              prose
              call)

            :else {:kind :tool-call
                   :program program
                   :rationale (when narrating? prose)
                   :tool-call-id (get call "id")
                   :public-tool-call call})))))))
