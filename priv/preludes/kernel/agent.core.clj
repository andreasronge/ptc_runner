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

(defn- retry-or-fail [turn max-turns reason]
  (if (agent.retry/retry? turn max-turns)
    true
    (fail (result/error :turn-limit reason))))

(defn- positive-int-or [value default maximum]
  (if (and (integer? value) (pos? value) (<= value maximum))
    value
    default))

(defn- completed-event [type turn max-turns]
  {:type type
   :turn turn
   :turns-remaining (- max-turns (inc turn))})

(defn- append-correlated [messages action content]
  (conj
    (conj messages
          {"role" "assistant"
           "content" nil
           "tool_calls" [(get action :public-tool-call)]})
    {"role" "tool"
     "tool_call_id" (get action :tool-call-id)
     "content" content}))

(defn- bounded-request [prompt-state messages max-transcript-chars]
  (let [request {"system" (system-message prompt-state)
                 "messages" messages
                 "tools" [(agent.native/tool-schema)]}
        encoded (json/generate-string request)]
    (cond
      (not (string? encoded))
      (fail (result/error :invalid-transcript :encoding-failed))

      (> (count encoded) max-transcript-chars)
      (fail (result/error :transcript-limit :request-too-large))

      :else request)))

(defn run [task cfg]
  (let [max-turns (positive-int-or (get cfg "max_turns") 4 128)
        max-program-chars (positive-int-or (get cfg "max_program_chars") 64000 1000000)
        max-observation-chars (positive-int-or (get cfg "max_observation_chars") 2048 16384)
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
             prompt-state initial-prompt-state]
        (if (>= turn max-turns)
          (fail (result/error :turn-limit :turn-limit-exceeded))
          (let [request (bounded-request prompt-state messages max-transcript-chars)
                response (llm/request request)
                action (agent.native/normalize response max-program-chars)]
            (workflow.event/annotate
              "agent-action"
              {:turn turn :kind (get action :kind)})
            (case (get action :kind)
              :tool-call
              (let [evaluation (kernel/eval-source (get action :program))]
                (case (get evaluation :outcome)
                  :returned
                  (if (false? (get effective-cfg "result_envelope"))
                    (return (get evaluation :value))
                    (return (result/ok (get evaluation :value))))
                  :failed (fail (result/error :model-program-failed (get evaluation :value)))
                  :continued
                  (do
                    (retry-or-fail turn max-turns :intermediate-result)
                    (let [event (completed-event :evaluation-success turn max-turns)
                          next-prompt-state (transition-prompt prompt-state event)
                          observation (agent.feedback/success evaluation max-observation-chars)]
                      (recur (inc turn)
                             (append-correlated messages action observation)
                             next-prompt-state)))
                  (if (false? (get evaluation :retryable?))
                    (fail (result/error :non-retryable-evaluation (get evaluation :kind)))
                    (do
                      (retry-or-fail turn max-turns :evaluation-error)
                      (let [next-prompt-state
                            (transition-prompt
                              prompt-state
                              (completed-event :evaluation-error turn max-turns))]
                        (recur (inc turn)
                               (append-correlated
                                 messages
                                 action
                                 (agent.feedback/evaluation-error evaluation))
                               next-prompt-state))))))

              :protocol-error
              (do
                (retry-or-fail turn max-turns :protocol-error)
                (let [next-prompt-state
                      (transition-prompt
                        prompt-state
                        (completed-event :protocol-error turn max-turns))]
                  (recur (inc turn)
                         (conj messages
                               {"role" "user"
                                "content" (agent.feedback/protocol-error action)})
                         next-prompt-state)))

              :provider-error
              (fail (result/error :llm-provider-error (get action :error)))

              (fail (result/error :unknown-action (get action :kind))))))))))
