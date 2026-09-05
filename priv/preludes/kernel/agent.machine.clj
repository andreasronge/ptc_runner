(ns agent.machine
  "Pure agent-loop reducer: immutable context/state and closed event-to-command
  transitions. Visibility is presentation only; exports remain callable and are
  not an authority boundary."
  {:visibility :discoverable})

(defn- nonblank-string? [value]
  (and (string? value) (not (blank? value))))

(defn- completed-event [type turn max-turns]
  {:type type
   :turn turn
   :turns-remaining (- max-turns (inc turn))})

(defn- next-phase? [phases phase-index]
  (< (inc phase-index) (count phases)))

(defn- phase-effective-cfg [cfg phase final-phase?]
  (let [phase-cfg (assoc (assoc (assoc cfg "mission" (get phase "mission"))
                                "max_turns" (get phase "max_turns"))
                         "terminal_only" (true? (get phase "terminal_only")))
        standalone (get cfg "standalone_return_contract")]
    (cond
      (and final-phase? (map? standalone))
      (assoc (assoc phase-cfg
                    "standalone_return_contract_name" (get standalone :name))
             "standalone_return_contract_projection" (get standalone :projection))

      final-phase?
      phase-cfg

      :else
      (assoc (assoc (assoc phase-cfg "result_contract" nil)
                    "return_contract" (get phase "return_contract"))
             "phase_return_contract" (get phase "return_contract_projection")))))

(defn- current-state [machine]
  (get machine :state))

(defn- current-context [machine]
  (get machine :context))

(defn- current-phase [machine]
  (get (get (current-context machine) :phases)
       (get (current-state machine) :phase-index)))

(defn- event-completed [type state phase]
  (completed-event type (get state :phase-turn) (get phase "max_turns")))

(defn- event-action [action]
  {:type :action :kind (get action :kind) :action action})

(defn- phase-turn-budget
  [turns-remaining consolidate-at-turns-remaining has-next-phase? return-contract?]
  (if (not has-next-phase?)
    (agent.feedback/turn-budget turns-remaining consolidate-at-turns-remaining)
    (str "PHASE BUDGET: " turns-remaining " "
         (if (= turns-remaining 1) "turn remains" "turns remain")
         " in the current mission phase, including the next program."
         (cond
           (and (= turns-remaining 1) return-contract?)
           "\nFINAL PHASE TURN: the next program must call (return value) satisfying the current phase contract, or (fail value). Exhaustion without an explicit return fails the phase."

           (= turns-remaining 1)
           "\nFINAL PHASE TURN: close the most material evidence gap. The host will then switch mission authority and continue with the retained transcript."

           (and (integer? consolidate-at-turns-remaining)
                (<= turns-remaining consolidate-at-turns-remaining))
           "\nCONSOLIDATE: prioritize the most material evidence gaps before the host changes phase."

           :else ""))))

(defn- with-phase-budget
  [content turns-remaining consolidate-at-turns-remaining has-next-phase? return-contract?]
  (str content "\n\n"
       (phase-turn-budget
         turns-remaining
         consolidate-at-turns-remaining
         has-next-phase?
         return-contract?)))

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
         has-next-phase?
         (string? (get phase "return_contract")))))

(defn- returned-outcome [value]
  {:status :returned :value value})

(defn- subject-failure [kind reason]
  {:status :subject-failure
   :kind kind
   :error (result/error kind reason)})

(defn- turn-limit-failure-with-evaluator
  [reason max-turns evaluator-failure-id]
  (let [outcome
        {:status :subject-failure
         :kind :turn-limit
         :error (assoc (result/error :turn-limit reason)
                       :limit :agent_turns
                       :limit_value max-turns)}]
    (if evaluator-failure-id
      (assoc outcome :evaluator-failure-id evaluator-failure-id)
      outcome)))

(defn- turn-limit-failure [reason max-turns]
  (turn-limit-failure-with-evaluator reason max-turns nil))

(defn- provider-failure [error model]
  (let [outcome {:status :provider-failure :error error}]
    (if (nonblank-string? model)
      (assoc outcome :model model)
      outcome)))

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

(defn- host-validation-unavailable-reason [evaluation]
  (let [reason (get evaluation :terminal-host-failure-reason)]
    (if (or (= reason :output_validation_unavailable)
            (= reason :output-validation-unavailable))
      :output-validation-unavailable
      :input-validation-unavailable)))

(defn- done [outcome]
  {:op :done :outcome outcome})

(defn- request-or-limit [machine]
  (let [state (current-state machine)
        phase (current-phase machine)
        max-turns (get phase "max_turns")]
    (if (>= (get state :phase-turn) max-turns)
      (done (turn-limit-failure
              :turn-limit-exceeded
              (get (current-context machine) :total-max-turns)))
      {:op :request :machine machine})))

(defn- request-continue [machine next-state]
  (request-or-limit
    {:context (current-context machine)
     :state (assoc next-state :agent-turn (inc (get (current-state machine) :agent-turn)))}))

(defn- continue-or [machine next-state fallback]
  ;; `fallback` is evaluated eagerly and must be a pure command map.
  (if (map? next-state)
    (if (get next-state :prompt-error)
      {:op :host-failure
       :error (result/error :invalid-prompt (get next-state :prompt-error))}
      (request-continue machine next-state))
    fallback))

(defn- transitioned-state [machine action content]
  (let [context (current-context machine)
        state (current-state machine)
        phases (get context :phases)
        phase-index (get state :phase-index)]
    (if (next-phase? phases phase-index)
      (let [next-index (inc phase-index)
            next-phase (get phases next-index)
            next-cfg (phase-effective-cfg (get context :effective-cfg)
                                          next-phase
                                          (not (next-phase? phases next-index)))
            next-prompt (agent.prompt/initial-state next-cfg)
            retained (append-agent-feedback (get state :messages) action content)]
        (if (map? next-prompt)
          {:phase-index next-index
           :phase-turn 0
           :phase-cfg next-cfg
           :messages
           (conj retained
                 {"role" "user"
                  "content"
                  (phase-transition-message
                    next-phase
                    (get context :consolidate-at-turns-remaining)
                    (next-phase? phases next-index))})
           :prompt-state next-prompt
           :closing? (get state :closing?)}
          {:prompt-error :invalid-initial-state}))
      nil)))

(defn- continuation-state [machine action content event-type]
  (let [context (current-context machine)
        state (current-state machine)
        phases (get context :phases)
        phase-index (get state :phase-index)
        phase (current-phase machine)
        event (event-completed event-type state phase)]
    (if (agent.retry/retry? (get state :phase-turn) (get phase "max_turns"))
      (let [next-prompt (agent.prompt/transition (get state :prompt-state) event)]
        (if (map? next-prompt)
          {:phase-index phase-index
           :phase-turn (inc (get state :phase-turn))
           :phase-cfg (get state :phase-cfg)
           :messages
           (append-agent-feedback
             (get state :messages)
             action
             (with-phase-budget
               content
               (get event :turns-remaining)
               (get context :consolidate-at-turns-remaining)
               (next-phase? phases phase-index)
               (string? (get phase "return_contract"))))
           :prompt-state next-prompt
           :closing? (get state :closing?)}
          {:prompt-error :invalid-transition}))
      (if (string? (get phase "return_contract"))
        nil
        (transitioned-state machine action content)))))

(defn- phase-contract-failure [machine completion value]
  {:op :phase-contract-failure
   :completion completion
   :value value
   :phase-index (inc (get (current-state machine) :phase-index))
   :mission (get (current-phase machine) "mission")
   :contract-name (get (current-phase machine) "return_contract")
   :max-turns (get (current-phase machine) "max_turns")})

(defn- exhaustion-fallback [machine fallback]
  (if (and (next-phase? (get (current-context machine) :phases)
                        (get (current-state machine) :phase-index))
           (string? (get (current-phase machine) "return_contract")))
    (phase-contract-failure machine :missing-return nil)
    fallback))

(defn- unsafe-closing-state [machine action evaluation]
  (let [state (current-state machine)
        event (event-completed :evaluation-error state (current-phase machine))
        next-prompt (agent.prompt/transition (get state :prompt-state) event)]
    (if (map? next-prompt)
      {:phase-index (get state :phase-index)
       :phase-turn (inc (get state :phase-turn))
       :phase-cfg (get state :phase-cfg)
       :messages
       (append-correlated
         (get state :messages)
         action
         ;; The closing instruction must remain the last and strongest
         ;; direction even when the hard turn limit has more runway.
         (str (agent.feedback/turn-budget
                (get event :turns-remaining)
                (get (current-context machine) :consolidate-at-turns-remaining))
              "\n\n"
              (agent.feedback/non-retryable evaluation)))
       :prompt-state next-prompt
       :closing? true}
      {:prompt-error :invalid-transition})))

(defn- decide-protocol-and-limits [machine event]
  (let [action (get event :action)
        kind (get event :kind)
        total-max-turns (get (current-context machine) :total-max-turns)]
    (cond
      (= :protocol-error kind)
      (continue-or
        machine
        (continuation-state
          machine action (agent.feedback/protocol-error action) :protocol-error)
        (exhaustion-fallback machine (done (turn-limit-failure :protocol-error total-max-turns))))

      (= :model-output-truncated kind)
      (let [limit (get action :output-limit)]
        {:op :runtime-limit
         :payload (if (map? limit)
                    {"max_tokens" (get limit "value")
                     "bindings" (get limit "bindings")
                     "alias" (get action :model)}
                    {"alias" (get action :model)})})

      (= :max-calls kind)
      (done
        (provider-failure
          (get action :error)
          (resolved-model action (get (current-state machine) :phase-cfg))))

      (= :provider-error kind)
      (if (agent.failure/classify (get action :error))
        (done
          (provider-failure
            (get action :error)
            (resolved-model action (get (current-state machine) :phase-cfg))))
        {:op :provider-consume :error (get action :error)})

      :else nil)))

(defn- decide-source-check [machine event]
  (let [action (get event :action)
        check (get event :check)
        total-max-turns (get (current-context machine) :total-max-turns)]
    (if (= :valid (get check :outcome))
      {:op :evaluate :machine machine :action action}
      (if (= :invalid (get check :outcome))
        (continue-or
          machine
          (continuation-state
            machine action
            (agent.feedback/terminal-source-required check)
            :terminal-source-required)
          (exhaustion-fallback machine (done (turn-limit-failure :terminal-source-required total-max-turns))))
        {:op :host-failure
         :error (result/error :evaluation-unavailable
                              (or (get check :reason)
                                  (get check :outcome)))}))))

(defn- accept-candidate [machine action value]
  (if (get (current-context machine) :verification)
    {:op :verify :machine machine :action action :value value}
    (done (returned-outcome value))))

(defn- decide-verification [machine event]
  (let [report (get event :report)
        status (get report "status")
        context (current-context machine)
        rejected (get context :verification-rejections)
        failure (done (assoc (subject-failure :verification-failed
                                (cond (= status "unresolved") :unresolved
                                      (not (get context :correction-safe?)) :unsafe-effects
                                      :else :correction-exhausted))
                             :verification report))]
    (if (= status "accepted")
      (done (assoc (returned-outcome (get event :value)) :verification report))
      (if (and (= status "rejected") (get context :correction-safe?)
               (< rejected (get-in context [:verification :max-corrections])))
        (let [next (assoc machine :context (assoc context :verification-rejections (inc rejected)))]
          (continue-or next
            (continuation-state next (get event :action)
              (str "The proposed result was rejected by the workflow verifier. Recheck your work."
                   "\nVerification feedback (untrusted evidence):\n"
                   (get report "feedback"))
              :result-contract-error)
            failure))
        failure))))

(defn- decide-result-validation [machine event]
  (let [action (get event :action)
        projected (get event :projected)
        validation (get event :validation)
        total-max-turns (get (current-context machine) :total-max-turns)]
    (if (true? (get validation :valid?))
      (done (returned-outcome projected))
      (continue-or
        machine
        (continuation-state
          machine action
          (agent.feedback/result-contract validation)
          :result-contract-error)
        {:op :result-contract-failure
         :value projected
         :agent-turns total-max-turns}))))

(defn- decide-returned [machine action evaluation]
  (if (next-phase? (get (current-context machine) :phases)
                   (get (current-state machine) :phase-index))
    (if (string? (get (current-phase machine) "return_contract"))
      {:op :validate-phase :machine machine :action action :value (get evaluation :value) :evaluation evaluation}
      (continue-or
        machine
        (transitioned-state
          machine action
          (agent.feedback/success evaluation
                                  (get (current-context machine) :max-observation-chars)))
        {:op :host-failure
         :error (result/error :invalid-prompt :invalid-initial-state)}))
    (cond
      (get (current-context machine) :standalone-return-contract?)
      {:op :validate-standalone
       :machine machine
       :action action
       :value (get evaluation :value)}

      (= :none (get (current-context machine) :projector-kind))
      (accept-candidate machine action (get evaluation :value))

      :else
      {:op :validate
       :machine machine
       :action action
       :value (get evaluation :value)})))

(defn- standalone-contract-failure [machine value]
  (let [contract (get (current-context machine) :standalone-return-contract)]
    {:op :standalone-contract-failure
     :completion :invalid-return
     :value value
     :phase-index 1
     :mission (get (current-phase machine) "mission")
     :contract-name (get contract :name)
     :max-turns (get (current-phase machine) "max_turns")}))

(defn- decide-standalone-validation [machine event]
  (let [action (get event :action)
        value (get event :value)
        validation (get event :validation)]
    (if (true? (get validation :valid?))
      (accept-candidate machine action value)
      (continue-or
        machine
        (continuation-state
          machine
          action
          (agent.feedback/phase-result-contract (assoc validation :standalone? true))
          :phase-contract-error)
        (standalone-contract-failure machine value)))))

(defn- decide-phase-validation [machine event]
  (let [action (get event :action)
        value (get event :value)
        evaluation (get event :evaluation)
        validation (get event :validation)]
    (if (true? (get validation :valid?))
      (continue-or
        machine
        (transitioned-state machine action (agent.feedback/success
                                             evaluation
                                             (get (current-context machine) :max-observation-chars)))
        {:op :host-failure :error (result/error :invalid-prompt :invalid-initial-state)})
      (continue-or
        machine
        (continuation-state machine action (agent.feedback/phase-result-contract validation) :phase-contract-error)
        (phase-contract-failure machine :invalid-return value)))))

(defn- decide-retryable-evaluation [machine action evaluation]
  (let [phase (current-phase machine)
        total-max-turns (get (current-context machine) :total-max-turns)]
    (if (false? (get evaluation :retryable?))
      ;; An unsafe failure forbids repeating the program, not salvaging the
      ;; run. Spend one closing turn asking for a decision from evidence
      ;; already gathered rather than discarding every prior evaluation; a
      ;; second unsafe failure ends it.
      (if (get (current-state machine) :closing?)
        (done (subject-failure :non-retryable-evaluation (get evaluation :kind)))
        (if (agent.retry/retry? (get (current-state machine) :phase-turn)
                                (get phase "max_turns"))
          (continue-or
            machine
            (unsafe-closing-state machine action evaluation)
            {:op :host-failure
             :error (result/error :invalid-prompt :invalid-transition)})
          (let [closing-machine
                {:context (current-context machine)
                 :state (assoc (current-state machine) :closing? true)}]
            (continue-or
              closing-machine
              (continuation-state
                closing-machine action
                (agent.feedback/non-retryable evaluation)
                :evaluation-error)
              (done (subject-failure :non-retryable-evaluation (get evaluation :kind)))))))
      (continue-or
        machine
        (continuation-state
          machine action
          (agent.feedback/evaluation-error evaluation)
          :evaluation-error)
        (exhaustion-fallback
          machine
          (done (turn-limit-failure-with-evaluator
                  :evaluation-error
                  total-max-turns
                  (get evaluation :evaluation_id))))))))

(defn- decide-evaluation [machine event]
  (let [action (get event :action)
        evaluation (get event :evaluation)
        context (current-context machine)
        unsafe? (or (false? (get evaluation :retryable?))
                    (and (or (= :returned (get evaluation :outcome)) (= :continued (get evaluation :outcome)))
                         (not (true? (get evaluation :correction_safe?)))))
        checked-machine (if unsafe? (assoc machine :context (assoc context :correction-safe? false)) machine)
        total-max-turns (get (current-context checked-machine) :total-max-turns)
        max-observation-chars (get (current-context checked-machine) :max-observation-chars)]
    ;; Host policy and malformed/provider-initiated MCP exchanges are not
    ;; argument mistakes the model can correct. The Kernel derives this
    ;; provenance from the private capability ledger, so it applies even when
    ;; a later expression fails.
    (cond
      (true? (get evaluation :terminal-host-failure?))
      {:op :host-failure
       :error (result/error :capability-unavailable
                            (host-validation-unavailable-reason evaluation))}

      (true? (get evaluation :terminal-provider-failure?))
      (done
        (subject-failure
          :model-program-failed
          (if (= :failed (get evaluation :outcome))
            (get evaluation :value)
            :terminal-provider-failure)))

      :else
      (case (get evaluation :outcome)
        :returned
        (decide-returned checked-machine action evaluation)

        :failed
        (if (correctable-capability-failure? evaluation)
          (continue-or
            checked-machine
            (continuation-state
              checked-machine action
              (agent.feedback/capability-error evaluation)
              :evaluation-error)
            (done (subject-failure :model-program-failed (get evaluation :value))))
          (done (subject-failure :model-program-failed (get evaluation :value))))

        :continued
        (continue-or
          checked-machine
          (continuation-state
            checked-machine action
            (agent.feedback/success evaluation max-observation-chars)
            :evaluation-success)
          (exhaustion-fallback checked-machine (done (turn-limit-failure :intermediate-result total-max-turns))))

        ;; A refused admission is a host condition, not something the model
        ;; wrote: either another caller holds the run's single evaluation
        ;; lease, or the run has spent its evaluation budget. Correcting the
        ;; program cannot clear either one, so this fails the outer workflow
        ;; rather than spending a turn and a model call on feedback the model
        ;; cannot act on.
        :busy
        {:op :host-failure
         :error (result/error :evaluation-unavailable (get evaluation :reason))}

        :limit_exceeded
        (if (= :subordinate_evaluations (get evaluation :reason))
          {:op :runtime-limit :payload {:proof (get evaluation :limit_proof)}}
          {:op :host-failure
           :error (result/error :evaluation-unavailable (get evaluation :reason))})

        (decide-retryable-evaluation checked-machine action evaluation)))))

(defn- decide-action [machine event]
  (let [action-event (event-action (get event :action))]
    (or (decide-protocol-and-limits machine action-event)
        (when (= :tool-call (get action-event :kind))
          {:op :check-source
           :machine machine
           :action (get action-event :action)})
        {:op :host-failure
         :error (result/error :unknown-action (get (get event :action) :kind))})))

(defn start
  "Constructs immutable context and initial loop state. Performs no effects.
  Returns `{:op :ok :machine ...}` or a host-failure command."
  {:signature "(task :string, context :map) -> :any"}
  [task context]
  (let [phases (get context :phases)
        initial-phase (first phases)
        initial-cfg (phase-effective-cfg (get context :effective-cfg)
                                         initial-phase
                                         (not (next-phase? phases 0)))
        initial-prompt-state (agent.prompt/initial-state initial-cfg)]
    (if (not (map? initial-prompt-state))
      {:op :host-failure
       :error (result/error :invalid-prompt :invalid-initial-state)}
      {:op :ok
       :machine
       {:context context
        :state
        ;; An instruction is delivered when its phase begins. Later phases
        ;; receive it in the transition message; the first phase has no
        ;; transition, so it rides with the initial task.
        {:phase-index 0
         :phase-turn 0
         :agent-turn 0
         :phase-cfg initial-cfg
         :messages [{"role" "user"
                     "content"
                     (with-phase-budget
                       (if (nonblank-string? (get initial-phase "instruction"))
                         (str task "\n\n" (get initial-phase "instruction"))
                         task)
                       (get initial-phase "max_turns")
                       (get context :consolidate-at-turns-remaining)
                       (next-phase? phases 0)
                       (string? (get initial-phase "return_contract")))}]
         :prompt-state initial-prompt-state
         :closing? false}}})))

(defn advance
  "One pure transition. Returns a closed command; never calls LLM, Kernel, tools, or fail."
  {:signature "(machine :map, event :any) -> :any"}
  [machine event]
  (if (not (map? event))
    {:op :host-failure :error (result/error :unknown-event :invalid-event)}
    (let [type (get event :type)]
      (cond
        (= :boot type)
        (request-or-limit machine)

        (= :action type)
        (decide-action machine event)

        (= :source-check type)
        (decide-source-check machine event)

        (= :evaluation type)
        (decide-evaluation machine event)

        (= :verification type)
        (decide-verification machine event)

        (= :validation type)
        (decide-result-validation machine event)

        (= :phase-validation type)
        (decide-phase-validation machine event)

        (= :standalone-validation type)
        (decide-standalone-validation machine event)

        :else
        {:op :host-failure :error (result/error :unknown-event type)}))))
