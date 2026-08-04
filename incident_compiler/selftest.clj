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

;; The transport carries record text as bytes, and text is not all ASCII. A
;; server whose stdout is in character mode renders a codepoint above 127 as an
;; escape rather than its UTF-8 bytes, which is not valid JSON — the frame is
;; refused, and because a stdio transport failure is terminal, one such record
;; ends the session. Fetching a record the caller names and handing its body
;; back verbatim makes that survivable-looking failure assertable.
(def probe-source
  (str "(return (get-in (incident.evidence/get-record (get data/params \"incident_id\")\n"
       "                                              (get data/params \"evidence_id\"))\n"
       "                [\"record\" \"body\"]))"))

(defn- probe-body [incident-id evidence-id]
  (let [evaluation (kernel/eval-source-with
                     probe-source
                     {"incident_id" incident-id "evidence_id" evidence-id})]
    (if (= :returned (get evaluation :outcome))
      (get evaluation :value)
      (fail (result/error :selftest-failed (get evaluation :outcome))))))

(defn run [input]
  (let [incident-id (get input "incident_id")
        evaluation (kernel/eval-source (mission-source incident-id))]
    (if (not= :returned (get evaluation :outcome))
      (fail (result/error :selftest-failed (get evaluation :outcome)))
      (return
        (assoc (get evaluation :value)
               "probe_body"
               (probe-body (get input "probe_incident_id")
                           (get input "probe_evidence_id")))))))
