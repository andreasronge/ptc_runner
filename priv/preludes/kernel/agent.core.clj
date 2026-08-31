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

(defn- consolidation-threshold [value max-turns]
  (if (nil? value)
    nil
    (if (and (integer? value) (pos? value) (<= value max-turns))
      value
      (fail (result/error :invalid-agent-config :invalid-consolidation-threshold)))))

(defn- nonblank-string? [value]
  (and (string? value) (not (blank? value))))

(defn- contract-name? [value]
  (and (string? value)
       (re-matches #"[a-z][a-z0-9._-]{0,127}" value)))

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
           (false? (get phase "terminal_only")))
       (or (nil? (get phase "return_contract"))
           (contract-name? (get phase "return_contract")))))

(defn- resolve-phase-contracts [phases]
  (let [final-phase (last phases)]
    (if (string? (get final-phase "return_contract"))
      (fail (result/error :invalid-agent-config :final-phase-return-contract))
      (mapv
        (fn [phase]
          (if (string? (get phase "return_contract"))
            (let [projection (kernel/phase-return-contract-presentation (get phase "return_contract"))]
              (if (= :error (get projection :status))
                (fail (result/error :invalid-agent-config (get projection :reason)))
                (assoc phase "return_contract_projection" projection)))
            phase))
        phases))))

(defn- resolve-standalone-contract [cfg projector-kind]
  (let [name (get cfg "return_contract")]
    (cond
      (nil? name)
      nil

      (not= projector-kind :none)
      (fail (result/error :invalid-agent-config :incompatible-return-contract))

      (contains? cfg "phases")
      (fail (result/error :invalid-agent-config :incompatible-return-contract))

      (not (contract-name? name))
      (fail (result/error :invalid-agent-config :invalid-return-contract))

      :else
      (let [projection (kernel/phase-return-contract-presentation name)]
        (if (= :error (get projection :status))
          (fail (result/error :invalid-agent-config (get projection :reason)))
          {:name name :projection projection})))))

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

(defn- loop-context [cfg projector-kind]
  (let [standalone-contract (resolve-standalone-contract cfg projector-kind)
        trusted-cfg (dissoc cfg "result_contract" "result_contract_mode"
                            "return_contract" "phase_return_contract"
                            "return_contract_projection"
                            "standalone_return_contract"
                            "standalone_return_contract_name"
                            "standalone_return_contract_projection")
        default-max-turns (bounded-option trusted-cfg "max_turns" 4 128)
        phases (resolve-phase-contracts (configured-phases trusted-cfg default-max-turns))
        total-max-turns (reduce + 0 (map #(get % "max_turns") phases))
        consolidate-at-turns-remaining
        (consolidation-threshold
          (get trusted-cfg "consolidate_at_turns_remaining")
          total-max-turns)
        max-program-chars (bounded-option trusted-cfg "max_program_chars" 64000 1000000)
        max-observation-chars (bounded-option trusted-cfg "max_observation_chars" 2048 65536)
        max-transcript-chars (bounded-option trusted-cfg "max_transcript_chars" 262144 1000000)
        presentation (when (not= projector-kind :none) (kernel/result-contract-presentation))
        effective-cfg (assoc trusted-cfg
                             "max_program_chars" max-program-chars
                             "max_observation_chars" max-observation-chars
                             "max_transcript_chars" max-transcript-chars
                             "result_contract" presentation
                             "result_contract_mode" projector-kind
                             "standalone_return_contract" standalone-contract)]
    {:effective-cfg effective-cfg
     :phases phases
     :total-max-turns total-max-turns
     :consolidate-at-turns-remaining consolidate-at-turns-remaining
     :max-program-chars max-program-chars
     :max-observation-chars max-observation-chars
     :max-transcript-chars max-transcript-chars
     :projector-kind projector-kind
     :standalone-return-contract standalone-contract
     :standalone-return-contract? (map? standalone-contract)
     :phased? (contains? trusted-cfg "phases")}))

(defn- machine-phase [machine]
  (get (get (get machine :context) :phases)
       (get (get machine :state) :phase-index)))

(defn- bounded-request [machine]
  (let [state (get machine :state)
        cfg (get state :phase-cfg)
        prompt-state (get state :prompt-state)
        messages (get state :messages)
        max-transcript-chars (get (get machine :context) :max-transcript-chars)
        base-request {"system" (system-message prompt-state)
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

(defn- propagate-provider-failure [error]
  ;; Named quota refusals and authenticated aggregate-budget refusals
  ;; authenticate through `fail` of the exact envelope.
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

(defn- project-value [kind value]
  (if (= :ok-envelope kind)
    (result/ok value)
    value))

(defn- annotate-action [machine action]
  (let [context (get machine :context)
        state (get machine :state)
        phase (machine-phase machine)]
    (workflow.event/annotate
      "agent-action"
      (if (get context :phased?)
        {:turn (get state :agent-turn)
         :phase (get state :phase-index)
         :phase-turn (get state :phase-turn)
         :mission (get phase "mission")
         :kind (get action :kind)}
        {:turn (get state :phase-turn) :kind (get action :kind)}))))

(defn- native-contract-violation [violation]
  (let [native {:kind (keyword (get violation "kind"))
                :path (get violation "path")}
        missing (get violation "missing_required")]
    (if (nil? missing)
      native
      (assoc native :missing_required missing))))

(defn- native-standalone-contract-error [response]
  (let [reason (get response "reason")
        details {:completion :invalid-return
                 :phase_index (get reason "phase_index")
                 :mission (get reason "mission")
                 :contract (get reason "contract")
                 :max_turns (get reason "max_turns")
                 :constraint (keyword (get reason "constraint"))
                 :violations (mapv native-contract-violation (get reason "violations"))}
        source (get reason "contract_source")]
    (result/error
      :phase-return-contract-failed
      (if (string? source) (assoc details :contract_source source) details))))

(defn- dispatch-request [machine]
  (let [action (agent.native/normalize
                 (llm/request (bounded-request machine))
                 (get (get machine :context) :max-program-chars))]
    (annotate-action machine action)
    action))

(defn- execute-command [cmd failure-mode]
  (let [op (get cmd :op)]
    (cond
      (= :host-failure op)
      (fail (get cmd :error))

      (= :provider-consume op)
      (fail
        (tool/kernel-llm-provider-failure
          (result/error :llm-provider-error (get cmd :error))))

      (= :runtime-limit op)
      (tool/kernel-runtime-limit-failure (get cmd :payload))

      (= :result-contract-failure op)
      (tool/kernel-result-contract-failure
        {"value" (get cmd :value) "agent_turns" (get cmd :agent-turns)})

      (= :phase-contract-failure op)
      (fail (result/error :phase-return-contract-failed
                          {:completion (get cmd :completion)
                           :phase_index (get cmd :phase-index)
                           :mission (get cmd :mission)
                           :contract (get cmd :contract-name)
                           :max_turns (get cmd :max-turns)}))

      (= :standalone-contract-failure op)
      (let [error
            (tool/kernel-phase-return-contract-failure
              {"value" (get cmd :value)
               "completion" "invalid_return"
               "phase_index" (get cmd :phase-index)
               "mission" (get cmd :mission)
               "contract" (get cmd :contract-name)
               "max_turns" (get cmd :max-turns)
               "mode" (if (= failure-mode :outcome) "outcome" "fail")})]
        (if (= failure-mode :outcome)
          {:status :subject-failure
           :kind :phase-return-contract-failed
           :error (native-standalone-contract-error error)}
          (fail error)))

      (= :config-failure op)
      (tool/kernel-agent-config-failure (get cmd :payload))

      :else
      (fail (result/error :unknown-command op)))))

(defn- run-outcome*
  "Runs the agent loop and distinguishes model-authored completion, a bounded
  subject-attributable failure, and a bounded provider failure.

  `projector-kind` is the internal final-result projection used before result-contract
  validation: `:none` skips validation, `:identity` keeps the model-authored value, and
  `:ok-envelope` wraps it in the standard success envelope. Prompt, transcript,
  evaluation-admission, provider-callback crashes, and other host/infrastructure
  failures still fail the outer workflow. Typed LLM envelopes, named quota
  refusals, aggregate-budget refusals, and alias-resolution protocol errors
  return as `:provider-failure` so a workflow that called this entry can
  inspect `kind` and `reason`. Fail-fast entries still abort those envelopes."
  [task cfg projector-kind failure-mode]
  (let [started (agent.machine/start task (loop-context cfg projector-kind))]
    (if (not= :ok (get started :op))
      (execute-command started failure-mode)
      (loop [machine (get started :machine)
             event {:type :boot}]
        (let [cmd (agent.machine/advance machine event)
              op (get cmd :op)]
          (cond
            (= :request op)
            (let [next (get cmd :machine)
                  action (dispatch-request next)
                  _counted (when (= :protocol-error (get action :kind))
                             (tool/kernel-agent-protocol-error {}))]
              (recur next {:type :action :action action}))

            (= :check-source op)
            (let [next (get cmd :machine)
                  action (get cmd :action)
                  phase (machine-phase next)
                  check (terminal-source-check
                          phase
                          (get phase "mission")
                          (get action :program))]
              (recur next {:type :source-check :action action :check check}))

            (= :evaluate op)
            (let [next (get cmd :machine)
                  action (get cmd :action)
                  phase (machine-phase next)
                  evaluation (evaluate-agent-source
                               (get phase "mission")
                               (get action :program)
                               (get (get next :context) :max-observation-chars))]
              (recur next {:type :evaluation :action action :evaluation evaluation}))

            (= :validate op)
            (let [next (get cmd :machine)
                  value (get cmd :value)
                  action (get cmd :action)
                  projected (project-value
                              (get (get next :context) :projector-kind)
                              value)
                  validation (kernel/validate-result projected)]
              (recur next {:type :validation
                           :action action
                           :projected projected
                           :validation validation}))

            (= :validate-phase op)
            (let [next (get cmd :machine)
                  value (get cmd :value)
                  evaluation (get cmd :evaluation)
                  action (get cmd :action)
                  phase (machine-phase next)
                  validation (kernel/validate-phase-return (get phase "return_contract") value)]
              (recur next {:type :phase-validation
                           :action action
                           :value value
                           :evaluation evaluation
                           :validation validation}))

            (= :validate-standalone op)
            (let [next (get cmd :machine)
                  value (get cmd :value)
                  action (get cmd :action)
                  contract (get (get next :context) :standalone-return-contract)
                  validation (kernel/validate-phase-return (get contract :name) value)]
              (recur next {:type :standalone-validation
                           :action action
                           :value value
                           :validation validation}))

            (= :done op)
            (get cmd :outcome)

            :else
            (execute-command cmd failure-mode)))))))

(defn run-outcome
  "Runs the agent loop and distinguishes model-authored completion from a
  bounded subject-attributable failure or a bounded provider failure. The
  returned outcome is workflow data; this entry does not validate against the
  manifest result contract. Set `return_contract` to a name declared under
  `contracts.phase_return_schemas` to validate each explicit return inside this
  standalone loop while correction turns remain.

  Provider failures return `{:status :provider-failure :error error :model alias}`
  with the complete bounded LLM envelope. The closed `kind` and `reason` are
  facts for workflow policy; this entry does not choose retry, failover, or
  abort. Restarting with another alias starts another loop and does not resume
  the previous transcript."
  {:signature "(task :string, cfg {model :string?, mission :string?, return_contract :any?, max_turns :any?, max_program_chars :any?, max_observation_chars :any?, max_transcript_chars :any?, consolidate_at_turns_remaining :int?}) -> :any"}
  [task cfg]
  (run-outcome* task cfg :none :outcome))

(defn run-value
  "Runs the agent loop and returns its model-authored value to the calling
  PTC-Lisp function. Unlike `run`, this does not terminate the outer program
  and does not validate against the manifest result contract, so an application
  can validate or score the answer before returning. Set `return_contract` to
  a declared named phase-return contract when the value crossing back to the
  workflow must be checked and corrected inside this standalone loop.

  Subject failures and provider failures retain the historical fail behavior.
  Evaluators that need to record those attempts use `run-outcome`."
  {:signature "(task :string, cfg {model :string?, mission :string?, return_contract :any?, max_turns :any?, max_program_chars :any?, max_observation_chars :any?, max_transcript_chars :any?, consolidate_at_turns_remaining :int?}) -> :any"}
  [task cfg]
  (propagate-outcome (run-outcome* task cfg :none :fail-fast)))

(defn run-result-value
  "Runs the agent loop and validates the raw model-authored value against the
  manifest result contract before returning it to the calling workflow. Use
  this when that raw value is itself the final contract-shaped application
  result."
  {:signature "(task :string, cfg {model :string?, mission :string?, max_turns :any?, max_program_chars :any?, max_observation_chars :any?, max_transcript_chars :any?, consolidate_at_turns_remaining :int?}) -> :any"}
  [task cfg]
  (propagate-outcome (run-outcome* task cfg :identity :fail-fast)))

(defn run-phased-result-value
  "Runs a sequence of bounded mission phases while retaining the exact
  correlated model and evaluation transcript. At each host-controlled phase
  boundary, the system prompt is rebuilt from the next mission's authority and
  that phase's instruction is appended as a user message. A return closes any
  non-final phase and is retained as evidence; only the final phase can complete
  the agent with a contract-valid result. A terminal-only phase rejects any
  parsed program whose single top-level form is not return or fail before
  mission evaluation, and only the final phase may declare terminal_only."
  {:signature "(task :string, cfg {model :string?, phases [{mission :string, max_turns :int, instruction :string?, terminal_only :bool?, return_contract :string?}], max_program_chars :any?, max_observation_chars :any?, max_transcript_chars :any?, consolidate_at_turns_remaining :int?}) -> :any"}
  [task cfg]
  (propagate-outcome (run-outcome* task cfg :identity :fail-fast)))

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
          :identity
          :ok-envelope)
        :fail-fast))))
