(ns agent.core "Provider-neutral scripted PTC-Lisp agent loop." {:visibility :prompt})

(defn- system-message [prompt-state]
  (let [prompt (agent.prompt/render prompt-state)]
    (cond
      (and (string? prompt) (not (blank? prompt)))
      prompt

      ;; The renderer answers the refused capability envelope rather than nil
      ;; when the mission context could not be produced, so the run reports the
      ;; cause -- `unknown_mission` for a manifest that declares no missions --
      ;; instead of only that the prompt was invalid.
      (map? prompt)
      (fail (assoc (result/error :mission-unavailable (get prompt :reason))
                   :cause prompt))

      :else
      (fail (result/error :invalid-prompt :invalid-render)))))

(defn- transition-prompt [prompt-state event]
  (let [next-state (agent.prompt/transition prompt-state event)]
    (if (map? next-state)
      next-state
      (fail (result/error :invalid-prompt :invalid-transition)))))

;; An explicitly out-of-range option is a caller mistake, not an omission:
;; silently substituting the default would make an invalid value
;; indistinguishable from leaving the option out and could spend more work
;; than the caller requested. The Kernel authors the command diagnostic from
;; a closed payload: an int64, or a type tag — never the original non-integer.
(defn- int64? [value]
  (and (integer? value)
       (>= value -9223372036854775808)
       (<= value 9223372036854775807)))

(defn- option-type [value]
  (cond
    (string? value) "string"
    (float? value) "float"
    (boolean? value) "bool"
    (map? value) "map"
    (vector? value) "vector"
    (nil? value) "nil"
    :else "other"))

(defn- bounded-option [cfg option default maximum]
  (let [value (get cfg option)]
    (if (nil? value)
      default
      (if (and (integer? value) (pos? value) (<= value maximum))
        value
        (if (int64? value)
          (tool/kernel-agent-config-failure
            {"option" option "min" 1 "max" maximum "value" value})
          (tool/kernel-agent-config-failure
            {"option" option "min" 1 "max" maximum "type" (option-type value)}))))))

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

(defn- nonblank-string? [value]
  (and (string? value) (not (blank? value))))

(defn- valid-phase? [phase]
  (and (map? phase)
       (nonblank-string? (get phase "mission"))
       (integer? (get phase "max_turns"))
       (pos? (get phase "max_turns"))
       (<= (get phase "max_turns") 128)
       (or (nil? (get phase "instruction"))
           (nonblank-string? (get phase "instruction")))
       (or (nil? (get phase "terminal_only"))
           (true? (get phase "terminal_only"))
           (false? (get phase "terminal_only")))))

(defn- configured-phases [cfg default-max-turns]
  (if (contains? cfg "phases")
    (let [phases (get cfg "phases")]
      (if (and (vector? phases)
               (seq phases)
               (<= (count phases) 8)
               (every? valid-phase? phases)
               (<= (reduce + 0 (map #(get % "max_turns") phases)) 128)
               ;; Only the final phase may be terminal-only: an earlier phase
               ;; that exhausts without a terminal action would hand off to
               ;; the next phase, silently voiding the obligation it declared.
               (not-any? #(true? (get % "terminal_only")) (butlast phases)))
        phases
        (fail (result/error :invalid-agent-config :invalid-phases))))
    ;; The synthesized default phase receives the same mission validation the
    ;; explicit phases do: a blank or non-string mission is a caller mistake,
    ;; not a lookup that should fail later under a different classification.
    (let [mission (or (get cfg "mission") "default")]
      (if (nonblank-string? mission)
        [{"mission" mission "max_turns" default-max-turns}]
        (fail (result/error :invalid-agent-config :invalid-mission))))))

(defn- next-phase? [phases phase-index]
  (< (inc phase-index) (count phases)))

(defn- phase-effective-cfg [cfg phase]
  (assoc (assoc (assoc cfg "mission" (get phase "mission"))
                "max_turns" (get phase "max_turns"))
         "terminal_only" (true? (get phase "terminal_only"))))

(defn- phase-turn-budget
  [turns-remaining consolidate-at-turns-remaining has-next-phase?]
  (if (not has-next-phase?)
    (agent.feedback/turn-budget turns-remaining consolidate-at-turns-remaining)
    (str "PHASE BUDGET: " turns-remaining " "
         (if (= turns-remaining 1) "turn remains" "turns remain")
         " in the current mission phase, including the next program."
         (cond
           (= turns-remaining 1)
           "\nFINAL PHASE TURN: close the most material evidence gap. The host will then switch mission authority and continue with the retained transcript."

           (and (integer? consolidate-at-turns-remaining)
                (<= turns-remaining consolidate-at-turns-remaining))
           "\nCONSOLIDATE: prioritize the most material evidence gaps before the host changes phase."

           :else ""))))

(defn- with-phase-budget
  [content turns-remaining consolidate-at-turns-remaining has-next-phase?]
  (str content "\n\n"
       (phase-turn-budget
         turns-remaining
         consolidate-at-turns-remaining
         has-next-phase?)))

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

(defn- append-protocol-error [messages action content]
  (if (= :program-too-large (get action :reason))
    (append-correlated
      messages
      {:rationale (get action :narration)
       :public-tool-call (get action :offending-call)
       :tool-call-id (get (get action :offending-call) "id")}
      content)
    (if (nonblank-string? (get action :narration))
      (conj
        (conj messages {"role" "assistant" "content" (get action :narration)})
        {"role" "user" "content" content})
      (conj messages {"role" "user" "content" content}))))

(defn- append-agent-feedback [messages action content]
  (cond
    (= :protocol-error (get action :kind))
    (append-protocol-error messages action content)

    (map? action)
    (append-correlated messages action content)

    :else
    (conj messages {"role" "user" "content" content})))

(defn- phase-transition-message
  [phase consolidate-at-turns-remaining has-next-phase?]
  (str "PHASE TRANSITION: The previous bounded mission phase is complete. "
       "Continue from the correlated evidence retained above. The system prompt now advertises the authoritative API for mission "
       (pr-str (get phase "mission")) ". Do not call APIs absent from that prompt.\n"
       (or (get phase "instruction") "Continue the task under the new mission authority.")
       "\n\n"
       (phase-turn-budget
         (get phase "max_turns")
         consolidate-at-turns-remaining
         has-next-phase?)))

(defn- transitioned-state
  [phases phase-index messages action content effective-cfg
   consolidate-at-turns-remaining closing?]
  (if (next-phase? phases phase-index)
    (let [next-index (inc phase-index)
          next-phase (get phases next-index)
          next-cfg (phase-effective-cfg effective-cfg next-phase)
          retained (append-agent-feedback messages action content)]
      {:phase-index next-index
       :turn 0
       :messages
       (conj retained
             {"role" "user"
              "content"
              (phase-transition-message
                next-phase
                consolidate-at-turns-remaining
                (next-phase? phases next-index))})
       :prompt-state (agent.prompt/initial-state next-cfg)
       :closing? closing?})
    nil))

(defn- continuation-state
  [phases phase-index turn messages action content prompt-state effective-cfg
   consolidate-at-turns-remaining closing? event-type]
  (let [phase (get phases phase-index)
        max-turns (get phase "max_turns")
        event (completed-event event-type turn max-turns)]
    (if (agent.retry/retry? turn max-turns)
      {:phase-index phase-index
       :turn (inc turn)
       :messages
       (append-agent-feedback
         messages
         action
         (with-phase-budget
           content
           (get event :turns-remaining)
           consolidate-at-turns-remaining
           (next-phase? phases phase-index)))
       :prompt-state (transition-prompt prompt-state event)
       :closing? closing?}
      (transitioned-state
        phases phase-index messages action content effective-cfg
        consolidate-at-turns-remaining closing?))))

(defn- bounded-request [prompt-state messages cfg max-transcript-chars]
  (let [base-request {"system" (system-message prompt-state)
                      "messages" messages
                      "tools" [(agent.native/tool-schema)]}
        request (if (contains? cfg "model")
                  (assoc base-request "model" (get cfg "model"))
                  base-request)
        encoded (json/generate-string request)]
    (if (> (count encoded) max-transcript-chars)
      ;; A ceiling the caller set in its own input document reports itself, the
      ;; way the turn limit does, instead of collapsing into `workflow_failed`.
      (tool/kernel-runtime-limit-failure {"max_transcript_chars" max-transcript-chars})
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

;; A bounded loop can end four ways and only two of them are answered by buying
;; more turns. The reason the loop already computed travels to the Kernel so the
;; command can say which one happened, instead of telling every caller to raise
;; max_turns.
(defn- turn-limit-reason-name [reason]
  (case reason
    :intermediate-result "intermediate-result"
    :evaluation-error "evaluation-error"
    :protocol-error "protocol-error"
    :terminal-source-required "terminal-source-required"
    "turn-limit-exceeded"))

(defn- propagate-subject-failure [outcome]
  (if (= :turn-limit (get outcome :kind))
    (tool/kernel-runtime-limit-failure
      {"agent_turns" (get (get outcome :error) :limit_value)
       "reason" (turn-limit-reason-name (get (get outcome :error) :reason))})
    (fail (get outcome :error))))

(defn- named-token [value]
  (cond
    (keyword? value) (name value)
    (string? value) value
    :else nil))

(defn- recoverable-llm-error? [error]
  (and (map? error)
       (let [kind (named-token (get error :kind))
             reason (named-token (get error :reason))]
         (or (and (or (= kind "provider-error") (= kind "provider_error"))
                  (or (= reason "denied")
                      (= reason "not-found") (= reason "not_found")
                      (= reason "unavailable")
                      (= reason "invalid-request") (= reason "invalid_request")
                      (= reason "internal")
                      (= reason "domain-error") (= reason "domain_error")
                      (= reason "invalid-result") (= reason "invalid_result")
                      (= reason "authentication-failed") (= reason "authentication_failed")
                      (= reason "payment-required") (= reason "payment_required")
                      (= reason "rate-limited") (= reason "rate_limited")
                      (= reason "tool-calling-unsupported") (= reason "tool_calling_unsupported")
                      (= reason "timeout")
                      (= reason "transport-error") (= reason "transport_error")))
             (and (or (= kind "protocol-error") (= kind "protocol_error"))
                  (or (= reason "unknown-model-alias") (= reason "unknown_model_alias")
                      (= reason "invalid-model-alias") (= reason "invalid_model_alias")
                      (= reason "model-alias-required") (= reason "model_alias_required")))
             (and (= kind "timeout")
                  (or (= reason "provider-timeout") (= reason "provider_timeout")))))))

(defn- resolved-model [action cfg]
  (let [error (get action :error)
        from-error (when (map? error) (get error :model))
        from-quota
        (when (map? error)
          (let [details (get error :details)]
            (when (map? details) (get details :alias))))
        from-cfg (get cfg "model")]
    (or (when (nonblank-string? from-error) from-error)
        (when (nonblank-string? from-quota) from-quota)
        (when (nonblank-string? from-cfg) from-cfg))))

(defn- provider-failure [error model]
  (let [outcome {:status :provider-failure :error error}]
    (if (nonblank-string? model)
      (assoc outcome :model model)
      outcome)))

(defn- propagate-provider-failure [error]
  ;; Named quota refusals authenticate through `fail` of the exact envelope.
  ;; Typed provider failures consume the Kernel's provider-failure evidence.
  ;; An unauthenticated envelope returns from the Kernel tool instead of
  ;; aborting, so fail-fast entries still abort that diagnostic.
  (if (= :max-calls (get (agent.native/normalize error 64000) :kind))
    (fail error)
    (fail
      (tool/kernel-llm-provider-failure
        (result/error :llm-provider-error error)))))

(defn- propagate-outcome [outcome]
  (case (get outcome :status)
    :returned (get outcome :value)
    :provider-failure (propagate-provider-failure (get outcome :error))
    (propagate-subject-failure outcome)))

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

(defn- terminal-source-check [phase mission-name source]
  (if (true? (get phase "terminal_only"))
    (kernel/check-terminal-source mission-name source)
    {:outcome :valid}))

(defn- project-ok [value]
  (result/ok value))

(defn- run-outcome*
  "Runs the agent loop and distinguishes model-authored completion, a bounded
  subject-attributable failure, and a bounded provider failure.

  `projector` is the internal final-result projection used before result-contract
  validation: nil skips validation, identity keeps the model-authored value, and
  `project-ok` wraps it in the standard success envelope. Prompt, transcript,
  evaluation-admission, provider-callback crashes, and other host/infrastructure
  failures still fail the outer workflow. Typed LLM envelopes, named quota
  refusals, and alias-resolution protocol errors return as `:provider-failure` so
  a workflow that called this entry can inspect `kind` and `reason`. Fail-fast
  entries still abort those envelopes."
  [task cfg projector]
  (let [default-max-turns (bounded-option cfg "max_turns" 4 128)
        phases (configured-phases cfg default-max-turns)
        total-max-turns (reduce + 0 (map #(get % "max_turns") phases))
        consolidate-at-turns-remaining
        (consolidation-threshold
          (get cfg "consolidate_at_turns_remaining")
          total-max-turns)
        max-program-chars (bounded-option cfg "max_program_chars" 64000 1000000)
        max-observation-chars (bounded-option cfg "max_observation_chars" 2048 65536)
        max-transcript-chars (bounded-option cfg "max_transcript_chars" 262144 1000000)
        effective-cfg (assoc cfg
                             "max_program_chars" max-program-chars
                             "max_observation_chars" max-observation-chars
                             "max_transcript_chars" max-transcript-chars)
        initial-phase (first phases)
        initial-effective-cfg (phase-effective-cfg effective-cfg initial-phase)
        initial-prompt-state (agent.prompt/initial-state initial-effective-cfg)
        phased? (contains? cfg "phases")]
    (if (not (map? initial-prompt-state))
      (fail (result/error :invalid-prompt :invalid-initial-state))
      (loop [turn 0
             agent-turn 0
             phase-index 0
             ;; An instruction is delivered when its phase begins. Later
             ;; phases receive it in the transition message; the first phase
             ;; has no transition, so it rides with the initial task.
             messages [{"role" "user"
                        "content"
                        (with-phase-budget
                          (if (nonblank-string? (get initial-phase "instruction"))
                            (str task "\n\n" (get initial-phase "instruction"))
                            task)
                          (get initial-phase "max_turns")
                          consolidate-at-turns-remaining
                          (next-phase? phases 0))}]
             prompt-state initial-prompt-state
             closing? false]
        (let [phase (get phases phase-index)
              max-turns (get phase "max_turns")
              mission-name (get phase "mission")
              current-effective-cfg (phase-effective-cfg effective-cfg phase)]
          (if (>= turn max-turns)
          (turn-limit-failure :turn-limit-exceeded total-max-turns)
          (let [request (bounded-request
                          prompt-state
                          messages
                          current-effective-cfg
                          max-transcript-chars)
                response (llm/request request)
                action (agent.native/normalize response max-program-chars)]
            (workflow.event/annotate
              "agent-action"
              (if phased?
                {:turn agent-turn
                 :phase phase-index
                 :phase-turn turn
                 :mission mission-name
                 :kind (get action :kind)}
                {:turn turn :kind (get action :kind)}))
            (case (get action :kind)
              :tool-call
              (let [source-check
                    (terminal-source-check phase mission-name (get action :program))]
                (if (= :valid (get source-check :outcome))
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
                                      (or (get evaluation :terminal-host-failure-reason)
                                          :input-validation-unavailable)))
                  (if (true? (get evaluation :terminal-provider-failure?))
                    (subject-failure
                      :model-program-failed
                      (if (= :failed (get evaluation :outcome))
                        (get evaluation :value)
                        :terminal-provider-failure))
                    (case (get evaluation :outcome)
                    :returned
                    (if (next-phase? phases phase-index)
                      (let [next-state
                            (transitioned-state
                              phases phase-index messages action
                              (agent.feedback/success evaluation max-observation-chars)
                              effective-cfg consolidate-at-turns-remaining closing?)]
                        (recur (get next-state :turn)
                               (inc agent-turn)
                               (get next-state :phase-index)
                               (get next-state :messages)
                               (get next-state :prompt-state)
                               (get next-state :closing?)))
                      (if (nil? projector)
                        (returned-outcome (get evaluation :value))
                        (let [projected (projector (get evaluation :value))
                              validation (kernel/validate-result projected)]
                          (if (true? (get validation :valid?))
                            (returned-outcome projected)
                            (let [next-state
                                  (continuation-state
                                    phases phase-index turn messages action
                                    (agent.feedback/result-contract validation)
                                    prompt-state effective-cfg
                                    consolidate-at-turns-remaining closing?
                                    :result-contract-error)]
                              (if next-state
                                (recur (get next-state :turn)
                                       (inc agent-turn)
                                       (get next-state :phase-index)
                                       (get next-state :messages)
                                       (get next-state :prompt-state)
                                       (get next-state :closing?))
                                (result-contract-failure
                                  projected
                                  total-max-turns)))))))
                    :failed
                    (if (correctable-capability-failure? evaluation)
                      (let [next-state
                            (continuation-state
                              phases phase-index turn messages action
                              (agent.feedback/capability-error evaluation)
                              prompt-state effective-cfg
                              consolidate-at-turns-remaining closing?
                              :evaluation-error)]
                        (if next-state
                          (recur (get next-state :turn)
                                 (inc agent-turn)
                                 (get next-state :phase-index)
                                 (get next-state :messages)
                                 (get next-state :prompt-state)
                                 (get next-state :closing?))
                          (subject-failure :model-program-failed (get evaluation :value))))
                      (subject-failure :model-program-failed (get evaluation :value)))
                    :continued
                    (let [next-state
                          (continuation-state
                            phases phase-index turn messages action
                            (agent.feedback/success evaluation max-observation-chars)
                            prompt-state effective-cfg
                            consolidate-at-turns-remaining closing?
                            :evaluation-success)]
                      (if next-state
                        (recur (get next-state :turn)
                               (inc agent-turn)
                               (get next-state :phase-index)
                               (get next-state :messages)
                               (get next-state :prompt-state)
                               (get next-state :closing?))
                        (turn-limit-failure :intermediate-result total-max-turns)))

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
                      (if closing?
                        (subject-failure :non-retryable-evaluation (get evaluation :kind))
                        (if (agent.retry/retry? turn max-turns)
                          (let [event (completed-event :evaluation-error turn max-turns)
                                next-prompt-state (transition-prompt prompt-state event)]
                            (recur (inc turn)
                                   (inc agent-turn)
                                   phase-index
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
                                   true))
                          (let [next-state
                                (continuation-state
                                  phases phase-index turn messages action
                                  (agent.feedback/non-retryable evaluation)
                                  prompt-state effective-cfg
                                  consolidate-at-turns-remaining true
                                  :evaluation-error)]
                            (if next-state
                              (recur (get next-state :turn)
                                     (inc agent-turn)
                                     (get next-state :phase-index)
                                     (get next-state :messages)
                                     (get next-state :prompt-state)
                                     (get next-state :closing?))
                              (subject-failure
                                :non-retryable-evaluation
                                (get evaluation :kind))))))
                      (let [next-state
                            (continuation-state
                              phases phase-index turn messages action
                              (agent.feedback/evaluation-error evaluation)
                              prompt-state effective-cfg
                              consolidate-at-turns-remaining closing?
                              :evaluation-error)]
                        (if next-state
                          (recur (get next-state :turn)
                                 (inc agent-turn)
                                 (get next-state :phase-index)
                                 (get next-state :messages)
                                 (get next-state :prompt-state)
                                 (get next-state :closing?))
                          (turn-limit-failure
                            :evaluation-error
                            total-max-turns))))))))
                  (if (= :invalid (get source-check :outcome))
                    (let [next-state
                          (continuation-state
                            phases phase-index turn messages action
                            (agent.feedback/terminal-source-required source-check)
                            prompt-state effective-cfg
                            consolidate-at-turns-remaining closing?
                            :terminal-source-required)]
                      (if next-state
                        (recur (get next-state :turn)
                               (inc agent-turn)
                               (get next-state :phase-index)
                               (get next-state :messages)
                               (get next-state :prompt-state)
                               (get next-state :closing?))
                        (turn-limit-failure
                          :terminal-source-required
                          total-max-turns)))
                    (fail (result/error :evaluation-unavailable
                                        (or (get source-check :reason)
                                            (get source-check :outcome)))))))

              :protocol-error
              (let [_counted (tool/kernel-agent-protocol-error {})
                    next-state
                    (continuation-state
                      phases phase-index turn messages action
                      (agent.feedback/protocol-error action)
                      prompt-state effective-cfg
                      consolidate-at-turns-remaining closing?
                      :protocol-error)]
                (if next-state
                  (recur (get next-state :turn)
                         (inc agent-turn)
                         (get next-state :phase-index)
                         (get next-state :messages)
                         (get next-state :prompt-state)
                         (get next-state :closing?))
                  (turn-limit-failure :protocol-error total-max-turns)))

              :model-output-truncated
              (let [limit (get action :output-limit)]
                (if (map? limit)
                  (tool/kernel-runtime-limit-failure
                    {"max_tokens" (get limit "value")
                     "bindings" (get limit "bindings")
                     "alias" (get action :model)})
                  (tool/kernel-runtime-limit-failure
                    {"alias" (get action :model)})))

              :max-calls
              (provider-failure
                (get action :error)
                (resolved-model action current-effective-cfg))

              :provider-error
              (if (recoverable-llm-error? (get action :error))
                (provider-failure
                  (get action :error)
                  (resolved-model action current-effective-cfg))
                (fail
                  (tool/kernel-llm-provider-failure
                    (result/error :llm-provider-error (get action :error)))))

              (fail (result/error :unknown-action (get action :kind)))))))))))

(defn run-outcome
  "Runs the agent loop and distinguishes model-authored completion from a
  bounded subject-attributable failure or a bounded provider failure. The
  returned outcome is workflow data; this entry does not validate against the
  manifest result contract.

  Provider failures return `{:status :provider-failure :error error :model alias}`
  with the complete bounded LLM envelope. The closed `kind` and `reason` are
  facts for workflow policy; this entry does not choose retry, failover, or
  abort. Restarting with another alias starts another loop and does not resume
  the previous transcript."
  {:signature "(task :string, cfg {model :string?, mission :string?, max_turns :any?, max_program_chars :any?, max_observation_chars :any?, max_transcript_chars :any?, consolidate_at_turns_remaining :int?}) -> :any"}
  [task cfg]
  (run-outcome* task cfg nil))

(defn run-value
  "Runs the agent loop and returns its model-authored value to the calling
  PTC-Lisp function. Unlike `run`, this does not terminate the outer program
  and does not validate against the manifest result contract, so an application
  can validate or score the answer before returning.

  Subject failures and provider failures retain the historical fail behavior.
  Evaluators that need to record those attempts use `run-outcome`."
  {:signature "(task :string, cfg {model :string?, mission :string?, max_turns :any?, max_program_chars :any?, max_observation_chars :any?, max_transcript_chars :any?, consolidate_at_turns_remaining :int?}) -> :any"}
  [task cfg]
  (propagate-outcome (run-outcome task cfg)))

(defn run-result-value
  "Runs the agent loop and validates the raw model-authored value against the
  manifest result contract before returning it to the calling workflow. Use
  this when that raw value is itself the final contract-shaped application
  result."
  {:signature "(task :string, cfg {model :string?, mission :string?, max_turns :any?, max_program_chars :any?, max_observation_chars :any?, max_transcript_chars :any?, consolidate_at_turns_remaining :int?}) -> :any"}
  [task cfg]
  (propagate-outcome (run-outcome* task cfg identity)))

(defn run-phased-result-value
  "Runs a sequence of bounded mission phases while retaining the exact
  correlated model and evaluation transcript. At each host-controlled phase
  boundary, the system prompt is rebuilt from the next mission's authority and
  that phase's instruction is appended as a user message. A return closes any
  non-final phase and is retained as evidence; only the final phase can complete
  the agent with a contract-valid result. A terminal-only phase rejects any
  parsed program whose single top-level form is not return or fail before
  mission evaluation, and only the final phase may declare terminal_only."
  {:signature "(task :string, cfg {model :string?, phases [{mission :string, max_turns :int, instruction :string?, terminal_only :bool?}], max_program_chars :any?, max_observation_chars :any?, max_transcript_chars :any?, consolidate_at_turns_remaining :int?}) -> :any"}
  [task cfg]
  (propagate-outcome (run-outcome* task cfg identity)))

(defn run
  "Runs the agent loop as a terminal workflow entry.

  The default result is a success envelope. Set `result_envelope` to false for
  a raw application value. The exact value this entry returns is validated
  against the manifest result contract while a correction turn remains: the
  envelope by default, or the raw value when `result_envelope` is false. Use
  `run-value` when the caller must continue after the model-authored value
  returns, and `run-result-value` when that raw value is itself the
  contract-shaped application result."
  {:signature "(task :string, cfg {model :string?, mission :string?, max_turns :any?, max_program_chars :any?, max_observation_chars :any?, max_transcript_chars :any?, consolidate_at_turns_remaining :int?, result_envelope :bool?}) -> :any"}
  [task cfg]
  (return
    (propagate-outcome
      (run-outcome*
        task
        cfg
        (if (false? (get cfg "result_envelope"))
          identity
          project-ok)))))
