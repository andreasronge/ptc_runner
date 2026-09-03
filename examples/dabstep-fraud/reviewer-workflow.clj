(ns dabstep.reviewer-regression
  "Run one fixed analyzer session through the normal independent reviewer and
  report what the workflow's own comparison caught.")

(defn- returned-outcome [outcome]
  (if (= :returned (get outcome :status))
    outcome
    (fail {:status :error :kind :review-stage-failed :outcome outcome})))

(defn run [input]
  (let [analyzer-result (get input "analyzer_result")
        programs (dabstep.review/reviewable-programs (get input "programs"))
        prompt (dabstep.review/prompt input analyzer-result programs)
        findings (get (returned-outcome
                        (agent.core/run-outcome
                          prompt
                          {"mission" "review"
                           "model" (get input "reviewer_model")
                           "max_turns" (get input "review_turns")
                           "return_contract" "findings"}))
                      :value)
        measured (get findings "countries")
        problems (get findings "problems")
        answer (get (get input "options")
                    (dabstep.review/top-country measured)
                    "Not Applicable")
        measurements-agree
        (every? (fn [derivation]
                  (dabstep.review/same-measurements? measured (get derivation "countries")))
                (get analyzer-result "derivations"))
        caught (or (not= answer (get analyzer-result "candidate_answer"))
                   (not measurements-agree)
                   (not (empty? problems)))]
    (if caught
      (return {"caught" true
               "case_id" (get input "case_id")
               "reviewer_answer" answer
               "measurements_agree" measurements-agree
               "problems" problems})
      (fail {:status :error
             :kind :reviewer-missed-defect
             :case (get input "case_id")}))))
