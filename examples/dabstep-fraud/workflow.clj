(ns dabstep.workflow
  "Two blind derivations of the same figures, then a review of the exact
  programs that produced them, then a decision made in workflow code.

  Each derivation has its own transcript, so the second cannot anchor on the
  first. The workflow retains every admitted analyzer program and gives the
  ordered source, original input, returned evidence, and candidate answer to a
  reviewer. The reviewer has the same read-only payment API, measures the
  figures itself, and reports problems it saw in the session.

  No model picks the answer. The derivations return per-country volumes; this
  workflow ranks them, renders the option `input.guidelines` requires, and
  publishes the answer only when all three measurements agree.")

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
      {"countries" (get (get outcome :value) "countries")
       "programs" (get outcome :programs)}
      (fail {:status :error
             :kind :incomplete-program-retention
             :stage mission
             :programs-omitted omitted}))))

(defn- bounded-prompt [prompt]
  (if (> (count prompt) 120000)
    (fail {:status :error
           :kind :review-prompt-too-large
           :characters (count prompt)
           :maximum 120000})
    prompt))

(defn- review [input analyzer-result programs]
  (let [outcome
        (agent.core/run-outcome
          (bounded-prompt (dabstep.review/prompt input analyzer-result programs))
          {"mission" "review"
           "model" (get input "reviewer_model")
           "max_turns" (get input "review_turns")
           "return_contract" "findings"
           "retain_programs" (get input "review_turns")
           "max_corrections" 1
           "verify" (fn [candidate]
                      (dabstep.review/verify-findings
                        (get analyzer-result "derivations") candidate))})]
    (if (= :verification-failed (get outcome :kind))
      (assoc (get-in outcome [:verification "evidence"]) "verified" false)
      (assoc (get (returned-outcome "review" outcome) :value) "verified" true))))

(defn run [input]
  (let [analysis (derive-once input "analysis")
        recheck (derive-once input "recheck")
        countries-a (get analysis "countries")
        countries-b (get recheck "countries")
        top-a (dabstep.review/top-country countries-a)
        top-b (dabstep.review/top-country countries-b)
        candidate (if (= top-a top-b)
                    (get (get input "options") top-a "Not Applicable")
                    "Not Applicable")
        findings (review input
                         {"derivations" [{"mission" "analysis" "countries" countries-a}
                                         {"mission" "recheck" "countries" countries-b}]
                          "candidate_answer" candidate}
                         (dabstep.review/reviewable-programs
                           (concat (get analysis "programs") (get recheck "programs"))))
        measured (get findings "countries")
        top-r (dabstep.review/top-country measured)
        agreed (and (true? (get findings "verified"))
                    (= top-a top-b top-r)
                    (dabstep.review/same-measurements? countries-a countries-b)
                    (dabstep.review/same-measurements? countries-a measured))]
    (return {"ok" true
             "value" (if agreed candidate "Not Applicable")
             "agreed" agreed
             "top_country" {"analysis" top-a "recheck" top-b "review" top-r}
             "problems" (get findings "problems")})))
