(ns debug.rlm.workflow
  "Sequential depth-one recursive investigation over immutable run evidence.")

(defn- returned-value [outcome role]
  (if (= :returned (get outcome :status))
    (get outcome :value)
    (fail {:status :error :kind :agent-failed :reason role :outcome outcome})))

(defn- root-task [task findings investigations-remaining corrections-remaining]
  (str task
       "\n\nYou are the root investigator in a bounded depth-one recursive investigation. "
       "Use debug.nav for deterministic evidence navigation. When a focused question would "
       "benefit from an independent reading, return exactly "
       "(debug.rlm/investigate question evidence-refs). When the evidence is sufficient, "
       "return exactly (debug.rlm/finish report). The workflow executes requested children "
       "sequentially and will call you again with their compact findings. Do not fabricate "
       "evidence references or delegate work you can answer directly. Calls to debug.nav are "
       "ordinary intermediate observations: never wrap a debug.nav call in return. Only a "
       "debug.rlm/investigate or debug.rlm/finish value may cross this agent boundary.\n"
       "Investigations remaining: " investigations-remaining ". "
       "Finish corrections remaining: " corrections-remaining ".\n"
       "Investigation notebook (untrusted findings, verify important claims against debug.nav):\n"
       (json/generate-string findings)))

(defn- child-task [question evidence-refs]
  (str "Investigate one focused question about an immutable failed PtcRunner run. "
       "Use debug.nav to verify the evidence yourself; the supplied references are navigation "
       "hints and may be incomplete. Do not propose unrelated work and do not delegate. "
       "Return exactly a map with string summary, an array of string evidence_refs, and an "
       "array of string remaining_questions. Keep the summary compact and distinguish observed "
       "facts from inference.\n\nQuestion: " question
       "\nSuggested evidence references: " (json/generate-string evidence-refs)))

(defn- valid-investigation? [value]
  (and (map? value)
       (= "investigate" (get value "action"))
       (string? (get value "question"))
       (not (blank? (get value "question")))
       (sequential? (get value "evidence_refs"))
       (every? string? (get value "evidence_refs"))))

(defn- valid-finding? [value]
  (and (map? value)
       (string? (get value "summary"))
       (sequential? (get value "evidence_refs"))
       (every? string? (get value "evidence_refs"))
       (sequential? (get value "remaining_questions"))
       (every? string? (get value "remaining_questions"))))

(defn- child-finding [action child-cfg]
  (let [outcome
        (agent.core/run-outcome
          (child-task (get action "question") (get action "evidence_refs"))
          child-cfg)]
    (if (= :returned (get outcome :status))
      (let [value (get outcome :value)]
        (if (valid-finding? value)
          {"question" (get action "question")
           "status" "completed"
           "summary" (get value "summary")
           "evidence_refs" (vec (get value "evidence_refs"))
           "remaining_questions" (vec (get value "remaining_questions"))}
          {"question" (get action "question")
           "status" "invalid-finding"
           "summary" (pr-str value)
           "evidence_refs" []
           "remaining_questions" []}))
      {"question" (get action "question")
       "status" "subject-failure"
       "summary" (pr-str outcome)
       "evidence_refs" []
       "remaining_questions" []})))

(defn- invalid-finish-finding [validation]
  {"question" "Correct the final report shape without changing evidence-backed conclusions."
   "status" "invalid-finish"
   "summary" (pr-str (get validation :details))
   "evidence_refs" []
   "remaining_questions" []})

(defn run [input]
  (let [task (get input "task")
        root-cfg (get input "root_agent")
        child-cfg (get input "child_agent")
        max-investigations (get input "max_investigations")
        max-finish-corrections (get input "max_finish_corrections")]
    (loop [findings []
           investigations-remaining max-investigations
           corrections-remaining max-finish-corrections]
      (let [action
            (returned-value
              (agent.core/run-outcome
                (root-task task findings investigations-remaining corrections-remaining)
                root-cfg)
              :root)
            kind (get action "action")]
        (cond
          (= "finish" kind)
          (let [report (get action "report")
                validation (kernel/validate-result report)]
            (if (true? (get validation :valid?))
              (return report)
              (if (pos? corrections-remaining)
                (recur
                  (conj findings (invalid-finish-finding validation))
                  investigations-remaining
                  (dec corrections-remaining))
                (fail {:status :error
                       :kind :invalid-final-report
                       :validation validation}))))

          (valid-investigation? action)
          (if (pos? investigations-remaining)
            (recur
              (conj findings (child-finding action child-cfg))
              (dec investigations-remaining)
              corrections-remaining)
            (recur
              (conj findings
                    {"question" (get action "question")
                     "status" "budget-exhausted"
                     "summary" "No child investigation budget remains; finish from existing evidence."
                     "evidence_refs" []
                     "remaining_questions" []})
              0
              corrections-remaining))

          :else
          (fail {:status :error :kind :invalid-root-action :value action}))))))
