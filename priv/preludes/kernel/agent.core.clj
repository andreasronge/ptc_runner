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

;; An explicitly out-of-range option is a caller mistake, not an omission:
;; silently substituting the default would make an invalid value
;; indistinguishable from leaving the option out and could spend more work
;; than the caller requested.
(defn- bounded-option [cfg option default maximum]
  (let [value (get cfg option)]
    (if (nil? value)
      default
      (if (and (integer? value) (pos? value) (<= value maximum))
        value
        (fail (assoc (result/error :invalid-agent-config :option-out-of-range)
                     :option option
                     :min 1
                     :max maximum))))))

(defn- completed-event [type turn max-turns]
  {:type type
   :turn turn
   :turns-remaining (- max-turns (inc turn))})

(defn- consolidation-threshold [value max-turns]
  (if (nil? value)
    nil
    (if (and (integer? value) (pos? value) (<= value max-turns))
      value
      (fail (result/error :invalid-agent-config :invalid-consolidation-threshold)))))

(defn- with-turn-budget [content turns-remaining consolidate-at-turns-remaining]
  (str content "\n\n"
       (agent.feedback/turn-budget turns-remaining consolidate-at-turns-remaining)))

(defn- completed-feedback [content event consolidate-at-turns-remaining]
  (with-turn-budget
    content
    (get event :turns-remaining)
    consolidate-at-turns-remaining))

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

(defn- bounded-request [prompt-state messages cfg max-transcript-chars]
  (let [base-request {"system" (system-message prompt-state)
                      "messages" messages
                      "tools" [(agent.native/tool-schema)]}
        request (if (contains? cfg "model")
                  (assoc base-request "model" (get cfg "model"))
                  base-request)
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

(defn- turn-limit-failure [reason max-turns]
  {:status :subject-failure
   :kind :turn-limit
   :error (assoc (result/error :turn-limit reason)
                 :limit :agent_turns
                 :limit_value max-turns)})

(defn- propagate-subject-failure [outcome]
  (if (= :turn-limit (get outcome :kind))
    (tool/kernel-runtime-limit-failure
      {"agent_turns" (get (get outcome :error) :limit_value)})
    (fail (get outcome :error))))

(defn- result-contract-failure [value max-turns]
  (tool/kernel-result-contract-failure
    {"value" value "agent_turns" max-turns}))

(defn- correctable-capability-failure? [evaluation]
  (let [error (get evaluation :value)]
    (and (true? (get evaluation :capability-failure?))
         (true? (get evaluation :retryable?))
         (map? error)
         (= "error" (get error :status))
         (string? (get error :kind))
         (string? (get error :reason))
         (or (true? (get error :retryable?))
             (false? (get error :retryable?))))))

(defn- evaluate-agent-source [mission-name source max-observation-chars]
  (let [response
        (tool/kernel-eval {:kind :source
                           :source source
                           :mission mission-name
                           :observation_chars max-observation-chars})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn- run-outcome*
  "Runs the agent loop and distinguishes model-authored completion from a
  bounded subject-attributable failure.

  Provider, prompt, transcript, quota, and other host/infrastructure failures
  still fail the outer workflow. This function is for evaluators that must
  score a model program failure, exhausted correction loop, or non-retryable
  generated-program error without misclassifying provider failure as subject
  behavior."
  [task cfg validate-result?]
  (let [max-turns (bounded-option cfg "max_turns" 4 128)
        consolidate-at-turns-remaining
        (consolidation-threshold
          (get cfg "consolidate_at_turns_remaining")
          max-turns)
        max-program-chars (bounded-option cfg "max_program_chars" 64000 1000000)
        max-observation-chars (bounded-option cfg "max_observation_chars" 2048 65536)
        max-transcript-chars (bounded-option cfg "max_transcript_chars" 262144 1000000)
        effective-cfg (assoc cfg
                             "max_turns" max-turns
                             "max_program_chars" max-program-chars
                             "max_observation_chars" max-observation-chars
                             "max_transcript_chars" max-transcript-chars)
        mission-name (or (get cfg "mission") "default")
        initial-prompt-state (agent.prompt/initial-state effective-cfg)]
    (if (not (and (string? mission-name) (not (blank? mission-name))))
      (fail (result/error :invalid-agent-config :invalid-mission))
      (if (not (map? initial-prompt-state))
      (fail (result/error :invalid-prompt :invalid-initial-state))
      (loop [turn 0
             messages [{"role" "user"
                        "content" (with-turn-budget
                                    task
                                    max-turns
                                    consolidate-at-turns-remaining)}]
             prompt-state initial-prompt-state
             closing? false]
        (if (>= turn max-turns)
          (turn-limit-failure :turn-limit-exceeded max-turns)
          (let [request (bounded-request prompt-state messages effective-cfg max-transcript-chars)
                response (llm/request request)
                action (agent.native/normalize response max-program-chars)]
            (workflow.event/annotate
              "agent-action"
              {:turn turn :kind (get action :kind)})
            (case (get action :kind)
              :tool-call
              (let [evaluation (evaluate-agent-source
                                 mission-name
                                 (get action :program)
                                 max-observation-chars)]
                ;; Host policy and malformed/provider-initiated MCP exchanges
                ;; are not argument mistakes the model can correct. The Kernel
                ;; derives this provenance from the private capability ledger,
                ;; so it applies even when a later expression fails.
                (if (true? (get evaluation :terminal-host-failure?))
                  (fail (result/error :capability-unavailable
                                      :input-validation-unavailable))
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
                                       (completed-feedback
                                         (agent.feedback/result-contract validation)
                                         event
                                         consolidate-at-turns-remaining))
                                     next-prompt-state
                                     closing?))
                            (result-contract-failure
                              (get evaluation :value)
                              max-turns))))
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
                                 (completed-feedback
                                   (agent.feedback/capability-error evaluation)
                                   event
                                   consolidate-at-turns-remaining))
                               next-prompt-state
                               closing?))
                      (subject-failure :model-program-failed (get evaluation :value)))
                    :continued
                    (if (agent.retry/retry? turn max-turns)
                      (let [event (completed-event :evaluation-success turn max-turns)
                            next-prompt-state (transition-prompt prompt-state event)
                            observation
                            (completed-feedback
                              (agent.feedback/success evaluation max-observation-chars)
                              event
                              consolidate-at-turns-remaining)]
                        (recur (inc turn)
                               (append-correlated messages action observation)
                               next-prompt-state
                               closing?))
                      (turn-limit-failure :intermediate-result max-turns))

                    ;; A refused admission is a host condition, not something
                    ;; the model wrote: either another caller holds the run's
                    ;; single evaluation lease, or the run has spent its
                    ;; evaluation budget. Correcting the program cannot clear
                    ;; either one, so this fails the outer workflow rather than
                    ;; spending a turn and a model call on feedback the model
                    ;; cannot act on.
                    :busy
                    (fail (result/error :evaluation-unavailable
                                        (get evaluation :reason)))

                    :limit_exceeded
                    (if (= :subordinate_evaluations (get evaluation :reason))
                      (tool/kernel-runtime-limit-failure
                        {:proof (get evaluation :limit_proof)})
                      (fail (result/error :evaluation-unavailable
                                          (get evaluation :reason))))

                    (if (false? (get evaluation :retryable?))
                      ;; An unsafe failure forbids repeating the program, not
                      ;; salvaging the run. Spend one closing turn asking for a
                      ;; decision from evidence already gathered rather than
                      ;; discarding every prior evaluation; a second unsafe
                      ;; failure ends it.
                      (if (or closing? (not (agent.retry/retry? turn max-turns)))
                        (subject-failure :non-retryable-evaluation (get evaluation :kind))
                        (let [event (completed-event :evaluation-error turn max-turns)
                              next-prompt-state (transition-prompt prompt-state event)]
                          (recur (inc turn)
                                 (append-correlated
                                   messages
                                   action
                                   ;; The closing instruction must remain the last
                                   ;; and strongest direction even when the hard
                                   ;; turn limit has more runway.
                                   (str (agent.feedback/turn-budget
                                          (get event :turns-remaining)
                                          consolidate-at-turns-remaining)
                                        "\n\n"
                                        (agent.feedback/non-retryable evaluation)))
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
                                   (completed-feedback
                                     (agent.feedback/evaluation-error evaluation)
                                     (completed-event :evaluation-error turn max-turns)
                                     consolidate-at-turns-remaining))
                                 next-prompt-state
                                 closing?))
                        (turn-limit-failure :evaluation-error max-turns)))))))

              :protocol-error
              (if (agent.retry/retry? turn max-turns)
                (let [next-prompt-state
                      (transition-prompt
                        prompt-state
                        (completed-event :protocol-error turn max-turns))]
                  (recur (inc turn)
                         (conj messages
                               {"role" "user"
                                "content" (completed-feedback
                                            (agent.feedback/protocol-error action)
                                            (completed-event :protocol-error turn max-turns)
                                            consolidate-at-turns-remaining)})
                         next-prompt-state
                         closing?))
                (turn-limit-failure :protocol-error max-turns))

              :provider-error
              (tool/kernel-llm-provider-failure
                (result/error :llm-provider-error (get action :error)))

              (fail (result/error :unknown-action (get action :kind)))))))))))

(defn run-outcome
  "Runs the agent loop and distinguishes model-authored completion from a
  bounded subject-attributable failure."
  {:signature "(task :string, cfg {model :string?, mission :string?, max_turns :int?, max_program_chars :int?, max_observation_chars :int?, max_transcript_chars :int?, consolidate_at_turns_remaining :int?}) -> :any"}
  [task cfg]
  (run-outcome* task cfg false))

(defn run-value
  "Runs the agent loop and returns its model-authored value to the calling
  PTC-Lisp function. Unlike `run`, this does not terminate the outer program,
  so an application can validate or score the answer before returning.

  Subject failures retain the historical fail behavior. Evaluators that need
  to record those attempts use `run-outcome`."
  {:signature "(task :string, cfg {model :string?, mission :string?, max_turns :int?, max_program_chars :int?, max_observation_chars :int?, max_transcript_chars :int?, consolidate_at_turns_remaining :int?}) -> :any"}
  [task cfg]
  (let [outcome (run-outcome task cfg)]
    (if (= :returned (get outcome :status))
      (get outcome :value)
      (propagate-subject-failure outcome))))

(defn run-result-value
  "Runs the agent loop and validates model-authored completion against the
  manifest result contract before returning it to the calling workflow."
  {:signature "(task :string, cfg {model :string?, mission :string?, max_turns :int?, max_program_chars :int?, max_observation_chars :int?, max_transcript_chars :int?, consolidate_at_turns_remaining :int?}) -> :any"}
  [task cfg]
  (let [outcome (run-outcome* task cfg true)]
    (if (= :returned (get outcome :status))
      (get outcome :value)
      (propagate-subject-failure outcome))))

(defn run
  "Runs the agent loop as a terminal workflow entry.

  The default result is a success envelope. Set `result_envelope` to false for
  a raw application value. Use `run-value` when the caller must continue after
  the model-authored value returns."
  {:signature "(task :string, cfg {model :string?, mission :string?, max_turns :int?, max_program_chars :int?, max_observation_chars :int?, max_transcript_chars :int?, consolidate_at_turns_remaining :int?, result_envelope :bool?}) -> :any"}
  [task cfg]
  (let [value (run-value task cfg)]
    (if (false? (get cfg "result_envelope"))
      (return value)
      (return (result/ok value)))))
