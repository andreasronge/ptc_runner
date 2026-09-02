(ns dabstep.reviewer-regression
  "Run one fixed analyzer session through the normal independent reviewer.")

(defn- returned-outcome [outcome]
  (if (= :returned (get outcome :status))
    outcome
    (fail {:status :error :kind :review-stage-failed :outcome outcome})))

(defn run [input]
  (let [programs (dabstep.review/reviewable-programs (get input "programs"))
        prompt (dabstep.review/prompt input (get input "analyzer_result") programs)
        review
        (returned-outcome
          (agent.core/run-outcome
            prompt
            {"mission" "review"
             "model" (get input "reviewer_model")
             "max_turns" (get input "review_turns")
             "return_contract" "findings"}))
        problems (get (get review :value) "problems")]
    (if (empty? problems)
      (fail {:status :error
             :kind :reviewer-missed-defect
             :case (get input "case_id")})
      (return {"caught" true
               "case_id" (get input "case_id")
               "problems" problems}))))
