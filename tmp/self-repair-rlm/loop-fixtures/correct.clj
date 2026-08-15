(ns loop-fixture.correct
  "Deterministic correction used only to exercise the host loop mechanics."
  {:visibility :prompt})

(defn run [feedback]
  (return
    {"decision" "propose-change"
     "run_id" (get-in feedback ["validation" "diagnosed_run_id"])
     "cause" "The observed total is 20 below the host-owned expected value; this fixture selects the base-charge component."
     "target_environment" "mission"
     "target_mission" "default"
     "component_id" "pricing.base"
     "function_id" "pricing.base/amount"
     "base_source_hash" "sha256:b8b7e4cd6c63c7a5062ba5777bf95dafc036aa2b6e53f5db62933c8e58889321"
     "candidate_source" "(ns pricing.base \"Base-charge calculation.\" {:visibility :discoverable})\n\n(defn amount\n  \"Calculate the base charge for a submitted subtotal.\"\n  {:signature \"(subtotal :int) -> :int\"}\n  [_subtotal]\n  100)\n"
     "evidence" ["Host validation expected total 120 and observed total 100 for subtotal 100."]}))
