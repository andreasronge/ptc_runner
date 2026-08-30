(ns dabstep.workflow
  "Two blind agent loops over the same data, then a blind review of their programs.

  Each loop is a separate agent run with its own transcript, so the second
  derivation cannot anchor on the first. The reviewer receives only program
  text: no data grant, no numbers, no earlier conversation.")

(defn- contract-brief [name]
  (str "\n\nThe JSON below DESCRIBES the shape your (return ...) value must have."
       " It is a schema description, not the value. Never return this description;"
       " return your own data arranged in this shape.\n"
       (json/generate-string (kernel/phase-return-contract-presentation name))))

(defn- checked [contract value]
  (let [check (kernel/validate-phase-return contract value)]
    (if (true? (get check :valid?))
      value
      (fail {:status :error :kind :contract-failed :contract contract :check check}))))

(defn- derive-once [input mission]
  (checked "evidence"
    (agent.core/run-value
      (str (get input "task") "\n\n" (get input "guidelines")
           (contract-brief "evidence"))
      {"mission" mission
       "model" (get input "model")
       "max_turns" (get input "work_turns")})))

(defn- numbered [programs]
  (join "\n\n---\n\n"
        (map (fn [i] (str "PROGRAM " i ":\n" (nth programs i)))
             (range (count programs)))))

(defn- ratio [c]
  (let [t (get c "total_volume")]
    (if (or (nil? t) (== 0 t)) 0 (/ (get c "fraudulent_volume") t))))

(defn- top-country [countries]
  (get (first (sort-by ratio > countries)) "ip_country"))

(defn run [input]
  (let [a (derive-once input "analysis")
        b (derive-once input "recheck")
        top-a (top-country (get a "countries"))
        top-b (top-country (get b "countries"))
        agree? (= top-a top-b)
        programs [(get a "program") (get b "program")]
        review (checked "findings"
                 (agent.core/run-value
                   (str (get input "review_task")
                        (contract-brief "findings")
                        "\n\n" (numbered programs))
                   {"mission" "review"
                    "model" (get input "model")
                    "max_turns" (get input "review_turns")}))
        blocking (filter #(= "blocking" (get % "severity")) (get review "defects"))]
    (println "top-a:" top-a "top-b:" top-b "agree?:" agree?)
    (println "programs-reviewed:" (get review "programs_reviewed"))
    (println "defects:" (get review "defects"))
    (println "blocking:" (count blocking))
    (return
      {"ok" true
       "value" (if (and agree? (empty? blocking))
                 (get (get input "options") top-a "Not Applicable")
                 "Not Applicable")})))
