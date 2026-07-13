(ns tutorial.agent "A small provider-neutral model-to-PTC-Lisp loop." {:visibility :prompt})

(defn- tool-schema []
  {"type" "function"
   "function"
   {"name" "run_ptc_lisp"
    "description" "Run one PTC-Lisp mission program ending in return or fail."
    "parameters"
    {"type" "object"
     "additionalProperties" false
     "required" ["program"]
     "properties" {"program" {"type" "string"}}}}})

(defn- protocol-error [reason]
  {:kind :protocol-error :reason reason})

(defn- call-name [call]
  (or (get call "name") (get-in call ["function" "name"])))

(defn- call-arguments [call]
  (let [arguments (or (get call "args")
                      (get call "arguments")
                      (get-in call ["function" "arguments"]))]
    (if (string? arguments)
      (json/parse-string arguments)
      arguments)))

(defn- normalize-action [response]
  (cond
    (and (map? response) (= :error (get response :status)))
    {:kind :provider-error :error response}

    (not (map? response))
    (protocol-error :invalid-response)

    (and (string? (get response "content"))
         (not (blank? (get response "content"))))
    (protocol-error :assistant-text-with-tool-call)

    :else
    (let [calls (get response "tool_calls")]
      (cond
        (not (sequential? calls))
        (protocol-error :missing-tool-call)

        (not= 1 (count calls))
        (protocol-error :multiple-or-missing-tool-calls)

        :else
        (let [call (first calls)
              arguments (call-arguments call)
              program (when (map? arguments) (get arguments "program"))]
          (cond
            (not= "run_ptc_lisp" (call-name call))
            (protocol-error :wrong-tool-name)

            (not (map? arguments))
            (protocol-error :invalid-json-arguments)

            (or (not= 1 (count arguments))
                (not (contains? arguments "program")))
            (protocol-error :extra-or-missing-arguments)

            (or (not (string? program)) (blank? program))
            (protocol-error :program-empty)

            (not (includes? program "(return"))
            (protocol-error :missing-explicit-return)

            :else
            {:kind :program :program program}))))))

(defn- request-model [messages]
  (let [response
        (tool/llm-request
          {"system" (str "Use run_ptc_lisp exactly once. Its program executes in a "
                         "confined mission environment. Do not answer in prose. "
                         "End successful programs with return and explicit failures with fail. "
                         "For this task, the program must return the granted file's content "
                         "as a string.")
           "messages" messages
           "tools" [(tool-schema)]})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn- valid-brief? [value]
  (string? value))

(defn run [input]
  (let [task (get input "task")]
    (loop [turn 0
           messages [{"role" "user" "content" task}]]
      (if (>= turn 4)
        (fail {"kind" "turn-limit" "turns" turn})
        (let [action (normalize-action (request-model messages))]
          (tool/workflow-annotate
            {"type" "agent-action"
             "data" {"turn" turn
                     "kind" (get action :kind)
                     "reason" (get action :reason)}})
          (case (get action :kind)
            :program
            (let [evaluation
                  (tool/kernel-eval
                    {"kind" :source "source" (get action :program)})]
              (case (get-in evaluation [:value :outcome])
                :returned
                (let [value (get-in evaluation [:value :value])]
                  (if (valid-brief? value)
                    (return
                      {"model_program" (get action :program)
                       "result" {"content" value}})
                    (recur
                      (inc turn)
                      (conj messages
                            {"role" "user"
                             "content"
                             (str "Your program ran, but its return value had the wrong shape. "
                                  "Return the file content as a string. Send one "
                                  "corrected run_ptc_lisp call.")}))))
                :failed (fail (get-in evaluation [:value :value]))
                (recur
                  (inc turn)
                  (conj messages
                        {"role" "user"
                         "content"
                         (str "The PTC-Lisp evaluation did not return successfully ("
                              (get-in evaluation [:value :outcome])
                              "). Send one corrected run_ptc_lisp call.")}))))

            :protocol-error
            (recur
              (inc turn)
              (conj messages
                    {"role" "user"
                     "content"
                     (str "Protocol error: " (get action :reason)
                          ". Call run_ptc_lisp exactly once with one program string.")}))

            :provider-error
            (fail {"kind" "llm-provider-error" "error" (get action :error)})

            (fail {"kind" "unknown-action" "action" action})))))))
