(ns loop-fixture.abstain
  "Deterministic abstention used only to exercise the host loop mechanics."
  {:visibility :prompt})

(defn run [feedback]
  (return
    {"decision" "insufficient-evidence"
     "run_id" (get-in feedback ["validation" "diagnosed_run_id"])
     "cause" "The validation mismatch does not uniquely identify a faulty component."
     "evidence" ["Host validation expected total 120 and observed total 100 for subtotal 100."]
     "missing_evidence" ["An independent invariant that assigns the discrepancy to one component."]}))
