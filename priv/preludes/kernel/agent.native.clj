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
        (and (= expected "max-calls") (= token "max_calls"))
        (and (= expected "workflow-capability-calls") (= token "workflow_capability_calls"))
        (and (= expected "workflow-capability-calls-per-name")
             (= token "workflow_capability_calls_per_name"))
        (and (= expected "mission-capability-calls") (= token "mission_capability_calls"))
        (and (= expected "mission-capability-calls-per-name")
             (= token "mission_capability_calls_per_name"))
        (and (= expected "llm-total-tokens") (= token "llm_total_tokens"))
        (and (= expected "llm-cost-microusd") (= token "llm_cost_microusd")))))

(defn- named-quota-limit? [value]
  (or (hyphenated? value "max-calls")
      (hyphenated? value "workflow-capability-calls")
      (hyphenated? value "workflow-capability-calls-per-name")
      (hyphenated? value "mission-capability-calls")
      (hyphenated? value "mission-capability-calls-per-name")))

(defn- max-calls-refusal? [response]
  (and (map? response)
       (let [details (get response :details)
             limit (when (map? details) (get details :limit))]
         (and (hyphenated? (get response :status) "error")
              (hyphenated? (get response :kind) "limit-exceeded")
              (hyphenated? (get response :reason) "capability-quota")
              (map? details)
              (named-quota-limit? limit)
              (integer? (get details :limit_value))
              (pos? (get details :limit_value))
              (if (hyphenated? limit "max-calls")
                (string? (get details :alias))
                (string? (get details :name)))))))

(defn- budget-refusal? [response]
  (and (map? response)
       (let [details (get response :details)
             limit (when (map? details) (get details :limit))
             reason (get response :reason)]
         (and (hyphenated? (get response :status) "error")
              (hyphenated? (get response :kind) "limit-exceeded")
              (or (hyphenated? reason "llm-total-tokens")
                  (hyphenated? reason "llm-cost-microusd"))
              (map? details)
              (or (and (hyphenated? reason "llm-total-tokens")
                       (hyphenated? limit "llm-total-tokens"))
                  (and (hyphenated? reason "llm-cost-microusd")
                       (hyphenated? limit "llm-cost-microusd")))
              (integer? (get details :limit_value))
              (pos? (get details :limit_value))
              (integer? (get details :requested))
              (>= (get details :requested) 0)
              (integer? (get details :remaining))
              (>= (get details :remaining) 0)
              (<= (get details :remaining) (get details :limit_value))
              (> (get details :requested) (get details :remaining))))))

(defn- normalize-action
  [response max-program-chars]
  (let [max-program-chars (if (and (integer? max-program-chars)
                                   (pos? max-program-chars)
                                   (<= max-program-chars 1000000))
                            max-program-chars
                            64000)]
  (cond
    (max-calls-refusal? response)
    {:kind :max-calls :error response}

    (budget-refusal? response)
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

(defn- valid-output-limit? [limit]
  (let [bindings (when (map? limit) (get limit "bindings"))
        canonical ["application_limit" "installation_param" "configured"
                   "adapter_default" "model_output_limit" "remaining_context"]]
    (and (map? limit)
         (= 3 (count limit))
         (= "max_tokens" (get limit "name"))
         (integer? (get limit "value"))
         (pos? (get limit "value"))
         (<= (get limit "value") 1000000)
         (sequential? bindings)
         (seq bindings)
         (= bindings (filter #(some #{%} bindings) canonical)))))

(defn- truncation-action [response]
  (let [limit (get response "output_limit")
        model (get response "model")]
    (when (and (= "length" (get response "finish_reason"))
               (or (nil? limit) (valid-output-limit? limit))
               (string? model)
               (not (blank? model)))
      (if (map? limit)
        {:kind :model-output-truncated
         :model model
         :output-limit limit}
        {:kind :model-output-truncated
         :model model}))))

(defn normalize
  "Normalizes one provider response into a usable tool call or a bounded terminal/recoverable action. A complete run_ptc_lisp call wins even when the provider reports output truncation."
  [response max-program-chars]
  (let [action (normalize-action response max-program-chars)]
    (if (= :tool-call (get action :kind))
      action
      (or (when (map? response) (truncation-action response))
          action))))
