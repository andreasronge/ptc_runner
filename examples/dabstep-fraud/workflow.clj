(ns dabstep.workflow
  "Two blind derivations of the same figure, followed in the same run by a
  review of the exact programs that produced them.

  Each derivation has its own transcript, so the second cannot anchor on the
  first. The workflow retains every admitted analyzer program and gives the
  ordered source, original input, returned evidence, and candidate answer to a
  fresh reviewer. The reviewer has the same read-only payment API and may copy
  or adapt analyzer code in its own run_ptc_lisp calls.

  The derivations see the original question but not each other's work. They
  return per-country volumes rather than picking a letter; this workflow ranks
  those figures and renders the answer in the form `input.guidelines` requires,
  using `input.options`.")

(defn- returned-outcome [stage outcome]
  (if (= :returned (get outcome :status))
    outcome
    (fail {:status :error :kind :agent-stage-failed :stage stage :outcome outcome})))

(defn- derive-once [input mission]
  (let [outcome
        (returned-outcome
          mission
          (agent.core/run-outcome
            (str (get input "task")
                 "\n\nReport the volumes you measured for every country you observed."
                 " Do not choose among the listed options; that decision is not"
                 " yours to make.")
            {"mission" mission
             "model" (get input "analyzer_model")
             "max_turns" (get input "work_turns")
             "return_contract" "evidence"
             "retain_programs" (get input "work_turns")}))
        omitted (get outcome :programs-omitted)]
    (if (= 0 omitted)
      {"evidence" (get outcome :value)
       "programs" (get outcome :programs)}
      (fail {:status :error
             :kind :incomplete-program-retention
             :stage mission
             :programs-omitted omitted}))))

(defn- ratio [c]
  (let [t (get c "total_volume")]
    (if (or (nil? t) (== 0 t)) 0 (/ (get c "fraudulent_volume") t))))

(defn- top-country [countries]
  (get (first (sort-by ratio > countries)) "ip_country"))

(defn run [input]
  (let [analysis (derive-once input "analysis")
        recheck (derive-once input "recheck")
        evidence-a (get analysis "evidence")
        evidence-b (get recheck "evidence")
        top-a (top-country (get evidence-a "countries"))
        top-b (top-country (get evidence-b "countries"))
        agree? (= top-a top-b)
        candidate (if agree?
                    (get (get input "options") top-a "Not Applicable")
                    "Not Applicable")
        retained-programs (into [] (concat (get analysis "programs")
                                           (get recheck "programs")))
        programs (dabstep.review/reviewable-programs retained-programs)
        analyzer-result {"analysis" evidence-a
                         "recheck" evidence-b
                         "candidate_answer" candidate}
        prompt (dabstep.review/prompt input analyzer-result programs)]
    (if (> (count prompt) 120000)
      (fail {:status :error
             :kind :review-prompt-too-large
             :characters (count prompt)
             :maximum 120000})
      (let [review
            (returned-outcome
              "review"
              (agent.core/run-outcome
                prompt
                {"mission" "review"
                 "model" (get input "reviewer_model")
                 "max_turns" (get input "review_turns")
                 "return_contract" "findings"
                 "retain_programs" (get input "review_turns")}))
            findings (get review :value)
            problems (get findings "problems")]
        (println "top-a:" top-a "top-b:" top-b "agree?:" agree?)
        (println "analyzer-programs:" (count retained-programs))
        (println "reviewer-input-programs:" (count programs))
        (println "rolled-back-programs:" (- (count retained-programs) (count programs)))
        (println "reviewer-programs:" (count (get review :programs)))
        (println "review-problems:" (count problems))
        (return
          {"ok" true
           "value" (if (and agree? (empty? problems))
                     candidate
                     "Not Applicable")})))))
