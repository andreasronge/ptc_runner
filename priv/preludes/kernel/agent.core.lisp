(ns agent.core "Provider-neutral scripted PTC-Lisp agent loop." {:visibility :prompt})

(defn- system-message []
  (str "Use the run_ptc_lisp tool exactly once per turn with one program string. "
       "End successful programs with return and explicit failures with fail. "
       "Do not answer in prose.\n\n"
       "Frozen mission inventory (JSON):\n"
       (kernel/mission-inventory)))

(defn- retry-or-fail [turn max-turns reason]
  (if (agent.retry/retry? turn max-turns)
    true
    (fail (result/error :turn-limit reason))))

(defn- positive-int-or [value default maximum]
  (if (and (integer? value) (pos? value) (<= value maximum))
    value
    default))

(defn run [task cfg]
  (let [max-turns (positive-int-or (get cfg "max_turns") 4 128)
        max-program-chars (positive-int-or (get cfg "max_program_chars") 64000 1000000)]
    (loop [turn 0
           messages [{"role" "user" "content" task}]]
      (if (>= turn max-turns)
        (fail (result/error :turn-limit :turn-limit-exceeded))
        (let [response (llm/request
                         {"system" (system-message)
                          "messages" messages
                          "tools" [(agent.native/tool-schema)]})
              action (agent.native/normalize response max-program-chars)]
          (workflow.event/annotate
            "agent-action"
            {:turn turn :kind (get action :kind)})
          (case (get action :kind)
            :tool-call
            (let [evaluation (kernel/eval-source (get action :program))]
              (case (get evaluation :outcome)
                :returned (return (result/ok (get evaluation :value)))
                :failed (fail (result/error :model-program-failed (get evaluation :value)))
                (do
                  (retry-or-fail turn max-turns :evaluation-error)
                  (recur (inc turn)
                         (conj
                           (conj messages
                                 {"role" "assistant"
                                  "content" nil
                                  "tool_calls" [(get action :public-tool-call)]})
                           {"role" "tool"
                            "tool_call_id" (get action :tool-call-id)
                            "content" (agent.feedback/evaluation-error evaluation)})))))

            :protocol-error
            (do
              (retry-or-fail turn max-turns :protocol-error)
              (recur (inc turn)
                     (conj messages
                           {"role" "user"
                            "content" (agent.feedback/protocol-error action)})))

            :provider-error
            (fail (result/error :llm-provider-error (get action :error)))

            (fail (result/error :unknown-action (get action :kind)))))))))
