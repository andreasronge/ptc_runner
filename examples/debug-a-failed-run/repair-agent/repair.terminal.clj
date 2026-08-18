(ns repair.terminal
  "Terminal correction actions. Call exactly one action as the top-level program; the action itself completes the evaluation, so do not wrap it in return."
  {:visibility :prompt})

(defn- nonblank-string? [value]
  (and (string? value) (not (blank? value))))

(defn- string-array? [value]
  (and (sequential? value)
       (seq value)
       (every? nonblank-string? value)))

(defn abstain
  "Complete with an insufficient-evidence report. Use this when the evidence does not distinguish one repair."
  {:signature "(run-id :string, cause :string, evidence [:string], missing-evidence [:string]) -> :map"}
  [run-id cause evidence missing-evidence]
  (if (and (nonblank-string? run-id)
           (nonblank-string? cause)
           (string-array? evidence)
           (string-array? missing-evidence))
    (return
      {"decision" "insufficient-evidence"
       "run_id" run-id
       "cause" cause
       "evidence" (vec evidence)
       "missing_evidence" (vec missing-evidence)})
    (fail "abstain requires run id, cause, non-empty evidence, and non-empty missing evidence")))

(defn propose
  "Complete with a propose-change report containing run_id, cause, target_environment, component_id, function_id, base_source_hash, candidate_source, and evidence. Include target_mission only for a mission target; a workflow target omits it, and a redundant one is dropped."
  {:signature "(report :map) -> :map"}
  [report]
  (if (map? report)
    (let [target-environment (get report "target_environment")
          proposal (assoc report "decision" "propose-change")]
      (cond
        (= "workflow" target-environment)
        (return (dissoc proposal "target_mission"))

        (and (= "mission" target-environment)
             (nonblank-string? (get report "target_mission")))
        (return proposal)

        :else
        (fail "propose requires target_environment workflow or mission, and a mission target requires a nonblank target_mission")))
    (fail "propose requires one report map")))
