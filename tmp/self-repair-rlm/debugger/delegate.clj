(ns debug.rlm
  "Depth-one delegation actions for the self-debugging experiment. These functions request work; the trusted workflow owns model calls and budgets."
  {:visibility :prompt})

(defn investigate
  "Request one focused child investigation. Evidence references are stable identifiers already observed through debug.nav, not copied evidence bodies."
  {:signature "(question :string, evidence_refs [:string]) -> :map"}
  [question evidence-refs]
  (if (and (string? question)
           (not (blank? question))
           (sequential? evidence-refs)
           (every? string? evidence-refs))
    {"action" "investigate"
     "question" question
     "evidence_refs" (vec evidence-refs)}
    (fail "investigate requires a non-blank question and an array of evidence-reference strings")))

(defn finish
  "Finish the recursive investigation with a candidate report. The workflow validates the nested report against the application result contract."
  {:signature "(report :map) -> :map"}
  [report]
  (if (map? report)
    {"action" "finish" "report" report}
    (fail "finish requires one report map")))
