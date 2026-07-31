(ns incident.selftest
  "Model-free check of the read-only evidence surface and citation resolver."
  {:visibility :prompt})

;; Deliberately no LLM provider: this exercises every installed evidence tool
;; and both citation-resolution failure modes deterministically, so a break in
;; the tool surface is diagnosed without spending a model turn on it.
(defn- mission-source [incident-id]
  (str/join
    "\n"
    [(str "(let [sources (incident.evidence/list-sources \"" incident-id "\")")
     (str "      found (incident.evidence/search \"" incident-id "\" nil nil 50)")
     "      first-id (get (first (get found \"records\")) \"evidence_id\")"
     (str "      record (incident.evidence/get-record \"" incident-id "\" first-id)")
     "      digest (get-in record [\"record\" \"content_digest\"])"
     (str "      resolved (incident.evidence/resolve-citations \"" incident-id "\"")
     "                 [{\"evidence_id\" first-id \"content_digest\" digest}])"
     (str "      unknown (incident.evidence/resolve-citations \"" incident-id "\"")
     "                [{\"evidence_id\" \"missing-record\" \"content_digest\" digest}])"
     (str "      tampered (incident.evidence/resolve-citations \"" incident-id "\"")
     "                 [{\"evidence_id\" first-id \"content_digest\""
     "                   \"sha256:0000000000000000000000000000000000000000000000000000000000000000\"}])]"
     "  (return {\"source_count\" (count (get sources \"sources\"))"
     "           \"record_count\" (get found \"matched\")"
     "           \"sampled_evidence_id\" first-id"
     "           \"resolved\" resolved"
     "           \"unknown\" unknown"
     "           \"tampered\" tampered}))"]))

(defn run [input]
  (let [incident-id (get input "incident_id")
        evaluation (kernel/eval-source (mission-source incident-id))]
    (if (= :returned (get evaluation :outcome))
      (return (get evaluation :value))
      (fail (result/error :selftest-failed (get evaluation :outcome))))))
