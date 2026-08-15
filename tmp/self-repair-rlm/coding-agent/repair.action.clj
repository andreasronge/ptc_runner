(ns repair.action
  "Typed constructors for a correction decision. Wrap exactly one constructor call in return; do not return a decision name by itself."
  {:visibility :prompt})

(defn- nonblank-string? [value]
  (and (string? value) (not (blank? value))))

(defn- string-array? [value]
  (and (sequential? value)
       (seq value)
       (every? nonblank-string? value)))

(defn abstain
  "Build a complete insufficient-evidence report. Use this when the evidence does not distinguish one repair."
  {:signature "(run-id :string, cause :string, evidence [:string], missing-evidence [:string]) -> :map"}
  [run-id cause evidence missing-evidence]
  (if (and (nonblank-string? run-id)
           (nonblank-string? cause)
           (string-array? evidence)
           (string-array? missing-evidence))
    {"decision" "insufficient-evidence"
     "run_id" run-id
     "cause" cause
     "evidence" (vec evidence)
     "missing_evidence" (vec missing-evidence)}
    (fail "abstain requires run id, cause, non-empty evidence, and non-empty missing evidence")))

(defn propose
  "Build a propose-change report from a map containing run_id, cause, target_environment, target_mission, component_id, function_id, base_source_hash, candidate_source, and evidence."
  {:signature "(report :map) -> :map"}
  [report]
  (if (map? report)
    (assoc report "decision" "propose-change")
    (fail "propose requires one report map")))
