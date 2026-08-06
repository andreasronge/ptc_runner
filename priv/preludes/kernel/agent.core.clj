(ns agent.core "Provider-neutral scripted PTC-Lisp agent loop." {:visibility :prompt})

(defn- system-message [prompt-state]
  (let [prompt (agent.prompt/render prompt-state)]
    (if (and (string? prompt) (not (blank? prompt)))
      prompt
      (fail (result/error :invalid-prompt :invalid-render)))))

(defn- transition-prompt [prompt-state event]
  (let [next-state (agent.prompt/transition prompt-state event)]
    (if (map? next-state)
      next-state
      (fail (result/error :invalid-prompt :invalid-transition)))))

(defn- positive-int-or [value default maximum]
  (if (and (integer? value) (pos? value) (<= value maximum))
    value
    default))

(defn- completed-event [type turn max-turns]
  {:type type
   :turn turn
   :turns-remaining (- max-turns (inc turn))})

;; The model's own narration is its stated plan for the turn. Dropping it left
;; the next turn seeing a tool result with no record of why it was requested.
(defn- append-correlated [messages action content]
  (conj
    (conj messages
          {"role" "assistant"
           "content" (get action :rationale)
           "tool_calls" [(get action :public-tool-call)]})
    {"role" "tool"
     "tool_call_id" (get action :tool-call-id)
     "content" content}))

(defn- bounded-request [prompt-state messages max-transcript-chars]
  (let [request {"system" (system-message prompt-state)
                 "messages" messages
                 "tools" [(agent.native/tool-schema)]}
        encoded (json/generate-string request)]
    (if (> (count encoded) max-transcript-chars)
      (fail (result/error :transcript-limit :request-too-large))
      request)))

(defn- returned-outcome [value]
  {:status :returned :value value})

(defn- subject-failure [kind reason]
  {:status :subject-failure
   :kind kind
   :error (result/error kind reason)})

(defn- correctable-capability-failure? [evaluation]
  (let [error (get evaluation :value)]
    (and (true? (get evaluation :capability-failure?))
         (true? (get evaluation :retryable?))
         (map? error)
         (= :error (get error :status))
         (keyword? (get error :kind))
         (keyword? (get error :reason))
         (or (true? (get error :retryable?))
             (false? (get error :retryable?))))))

(defn- run-outcome*
  "Runs the agent loop and distinguishes model-authored completion from a
  bounded subject-attributable failure.

  Provider, prompt, transcript, quota, and other host/infrastructure failures
  still fail the outer workflow. This function is for evaluators that must
  score a model program failure, exhausted correction loop, or non-retryable
  generated-program error without misclassifying provider failure as subject
  behavior."
  [task cfg validate-result?]
  (let [max-turns (positive-int-or (get cfg "max_turns") 4 128)
        max-program-chars (positive-int-or (get cfg "max_program_chars") 64000 1000000)
        max-observation-chars (positive-int-or (get cfg "max_observation_chars") 2048 65536)
        max-transcript-chars (positive-int-or (get cfg "max_transcript_chars") 262144 1000000)
        effective-cfg (assoc cfg
                             "max_turns" max-turns
                             "max_program_chars" max-program-chars
                             "max_observation_chars" max-observation-chars
                             "max_transcript_chars" max-transcript-chars)
        initial-prompt-state (agent.prompt/initial-state effective-cfg)]
    (if (not (map? initial-prompt-state))
      (fail (result/error :invalid-prompt :invalid-initial-state))
      (loop [turn 0
             messages [{"role" "user" "content" task}]
             prompt-state initial-prompt-state
             closing? false]
        (if (>= turn max-turns)
          (subject-failure :turn-limit :turn-limit-exceeded)
          (let [request (bounded-request prompt-state messages max-transcript-chars)
                response (llm/request request)
                action (agent.native/normalize response max-program-chars)]
            (workflow.event/annotate
              "agent-action"
              {:turn turn :kind (get action :kind)})
            (case (get action :kind)
              :tool-call
              (let [evaluation (kernel/eval-source (get action :program))]
                ;; Host policy and malformed/provider-initiated MCP exchanges
                ;; are not argument mistakes the model can correct. The Kernel
                ;; derives this provenance from the private capability ledger,
                ;; so it applies even when a later expression fails.
                (if (true? (get evaluation :terminal-provider-failure?))
                  (subject-failure
                    :model-program-failed
                    (if (= :failed (get evaluation :outcome))
                      (get evaluation :value)
                      :terminal-provider-failure))
                  (case (get evaluation :outcome)
                    :returned
                    (if validate-result?
                      (let [validation (kernel/validate-result (get evaluation :value))]
                        (if (true? (get validation :valid?))
                          (returned-outcome (get evaluation :value))
                          (if (agent.retry/retry? turn max-turns)
                            (let [event (completed-event :result-contract-error turn max-turns)
                                  next-prompt-state (transition-prompt prompt-state event)]
                              (recur (inc turn)
                                     (append-correlated
                                       messages
                                       action
                                       (agent.feedback/result-contract validation))
                                     next-prompt-state
                                     closing?))
                            (subject-failure :result-contract :invalid-result))))
                      (returned-outcome (get evaluation :value)))
                    :failed
                    (if (and (correctable-capability-failure? evaluation)
                             (agent.retry/retry? turn max-turns))
                      (let [event (completed-event :evaluation-error turn max-turns)
                            next-prompt-state (transition-prompt prompt-state event)]
                        (recur (inc turn)
                               (append-correlated
                                 messages
                                 action
                                 (agent.feedback/capability-error evaluation))
                               next-prompt-state
                               closing?))
                      (subject-failure :model-program-failed (get evaluation :value)))
                    :continued
                    (if (agent.retry/retry? turn max-turns)
                      (let [event (completed-event :evaluation-success turn max-turns)
                            next-prompt-state (transition-prompt prompt-state event)
                            observation (agent.feedback/success evaluation max-observation-chars)]
                        (recur (inc turn)
                               (append-correlated messages action observation)
                               next-prompt-state
                               closing?))
                      (subject-failure :turn-limit :intermediate-result))
                    (if (false? (get evaluation :retryable?))
                      ;; An unsafe failure forbids repeating the program, not
                      ;; salvaging the run. Spend one closing turn asking for a
                      ;; decision from evidence already gathered rather than
                      ;; discarding every prior evaluation; a second unsafe
                      ;; failure ends it.
                      (if (or closing? (not (agent.retry/retry? turn max-turns)))
                        (subject-failure :non-retryable-evaluation (get evaluation :kind))
                        (let [next-prompt-state
                              (transition-prompt
                                prompt-state
                                (completed-event :evaluation-error turn max-turns))]
                          (recur (inc turn)
                                 (append-correlated
                                   messages
                                   action
                                   (agent.feedback/non-retryable evaluation))
                                 next-prompt-state
                                 true)))
                      (if (agent.retry/retry? turn max-turns)
                        (let [next-prompt-state
                              (transition-prompt
                                prompt-state
                                (completed-event :evaluation-error turn max-turns))]
                          (recur (inc turn)
                                 (append-correlated
                                   messages
                                   action
                                   (agent.feedback/evaluation-error evaluation))
                                 next-prompt-state
                                 closing?))
                        (subject-failure :turn-limit :evaluation-error))))))

              :protocol-error
              (if (agent.retry/retry? turn max-turns)
                (let [next-prompt-state
                      (transition-prompt
                        prompt-state
                        (completed-event :protocol-error turn max-turns))]
                  (recur (inc turn)
                         (conj messages
                               {"role" "user"
                                "content" (agent.feedback/protocol-error action)})
                         next-prompt-state
                         closing?))
                (subject-failure :turn-limit :protocol-error))

              :provider-error
              (fail (result/error :llm-provider-error (get action :error)))

              (fail (result/error :unknown-action (get action :kind))))))))))

(defn run-outcome
  "Runs the agent loop and distinguishes model-authored completion from a
  bounded subject-attributable failure."
  [task cfg]
  (run-outcome* task cfg false))

(defn run-value
  "Runs the agent loop and returns its model-authored value to the calling
  PTC-Lisp function. Unlike `run`, this does not terminate the outer program,
  so an application can validate or score the answer before returning.

  Subject failures retain the historical fail behavior. Evaluators that need
  to record those attempts use `run-outcome`."
  [task cfg]
  (let [outcome (run-outcome task cfg)]
    (if (= :returned (get outcome :status))
      (get outcome :value)
      (fail (get outcome :error)))))

(defn run-result-value
  "Runs the agent loop and validates model-authored completion against the
  manifest result contract before returning it to the calling workflow."
  [task cfg]
  (let [outcome (run-outcome* task cfg true)]
    (if (= :returned (get outcome :status))
      (get outcome :value)
      (fail (get outcome :error)))))

(defn run
  "Runs the agent loop as a terminal workflow entry.

  The default result is a success envelope. Set `result_envelope` to false for
  a raw application value. Use `run-value` when the caller must continue after
  the model-authored value returns."
  [task cfg]
  (let [value (run-value task cfg)]
    (if (false? (get cfg "result_envelope"))
      (return value)
      (return (result/ok value)))))
