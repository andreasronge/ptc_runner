(ns singleshot
  "The single-pass incident compiler."
  {:visibility :prompt})

(defn run
  "Compile one incident into a cited report in a single model pass.

  Takes an incident identifier and fetches that incident's evidence records
  itself — it is not handed the records. Every record it fetches carries an
  evidence_id, observed_at, source, title, body, and content_digest.

  Produces a report whose timeline and observed_facts each cite the records
  they rest on, whose root-cause hypotheses are kept separate from those
  observed facts and carry both supporting and contradicting citations, and
  whose open_questions record what the evidence does not answer. Every
  citation is resolved against the evidence source before the report is
  returned, and publication fails closed if any citation does not resolve.

  It does this in one model pass: all record bodies go into one prompt and the
  whole report comes back in one reply.

  Assumes all record bodies fit comfortably in one prompt; that one pass is
  enough, since there is no correction turn if the report is thin,
  contradictory, or misses something the evidence supports; and that no
  adaptive retrieval is needed, since it cannot search again after reading.

  A poor fit when the evidence is large, spans many sources that must be
  reconciled, contains contradictions needing several passes to resolve, or
  where deciding what to read depends on what was already read."
  {:signature "(incident_id :string) -> {status :string, timeline [:map], observed_facts [:map], hypotheses [:map], open_questions [:map]}"
   :effect :read}
  [incident-id]
  (return incident-id))
