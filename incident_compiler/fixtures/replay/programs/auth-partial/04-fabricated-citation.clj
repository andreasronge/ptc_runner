;; Scripted defect, and the one the result contract cannot catch. Every field
;; is structurally correct: the fabricated citation names a plausible record and
;; carries a real, correctly formatted digest borrowed from another record. Only
;; resolving the identifier against the evidence source rejects it — which is
;; why the compiler resolves every citation before it publishes.
(defn fabricate [evidence-id borrowed-from]
  {"evidence_id" evidence-id
   "content_digest" (get (get records borrowed-from) "content_digest")})

(return
  {"status" "report"
   "incident_id" "auth-partial"
   "summary"
   "From 06:41:30Z on 2026-06-21, sessions written before an auth-service session-store client upgrade became unreadable, and roughly a third of login attempts failed until a compatibility flag was set at 07:58:00Z."
   "timeline"
   [{"observed_at" "2026-06-21T06:41:30Z"
     "statement" "The auth-service session-store client was upgraded from 3.2.1 to 4.0.0."
     "citations" [(cite "deploy-4402")]}
    {"observed_at" "2026-06-21T07:00:00Z"
     "statement" "A scheduled eu-west rack maintenance window opened."
     "citations" [(cite "maint-0091")]}
    {"observed_at" "2026-06-21T07:04:58Z"
     "statement" "us-east session lookups began returning not_found for keys written before the upgrade."
     "citations" [(cite "log-31200")]}
    {"observed_at" "2026-06-21T07:58:00Z"
     "statement" "The compatibility flag was set and auth-service restarted in us-east."
     "citations" [(cite "chat-2258")]}]
   "observed_facts"
   [{"statement" "The login failure ratio reached 0.31 of attempts against an objective of 0.02, aggregated across all regions."
     "citations" [(cite "alert-6603")]}
    {"statement" "The 4.0.0 session-store client changed default key serialization from string to binary and requires an explicit compatibility flag for mixed-version fleets."
     "citations" [(cite "deploy-4402")]}
    {"statement" "In us-east, sessions written before 06:41:30Z returned not_found while sessions written after it resolved normally."
     "citations" [(cite "log-31200")]}
    {"statement" "A sampled failing login returned 401 after a session lookup miss and never contacted the identity provider."
     "citations" [(cite "trace-9c40")]}
    {"statement" "No auth-service log lines from eu-west are retained for the incident window, because that region's log shipper was down from 06:52:00Z."
     "citations" [(cite "log-31488")]}
    {"statement" "The eu-west region was unaffected throughout the incident, and its login failure ratio stayed within objective."
     "citations" [(fabricate "log-31700" "log-31200")]}]
   "hypotheses"
   [{"statement" "The session-store client upgrade made pre-upgrade session keys unreadable and caused the login failures."
     "confidence" "high"
     "supporting_citations"
     [(cite "deploy-4402") (cite "log-31200") (cite "trace-9c40") (cite "chat-2258")]
     "contradicting_citations" []}
    {"statement" "The eu-west maintenance window caused the login failures."
     "confidence" "low"
     "supporting_citations" [(cite "chat-2201")]
     "contradicting_citations" [(cite "maint-0091") (cite "trace-9c40")]}
    {"statement" "The upstream identity provider rejected tokens and caused the login failures."
     "confidence" "low"
     "supporting_citations" [(cite "chat-2209")]
     "contradicting_citations" [(cite "trace-9c40") (cite "chat-2231")]}]
   "open_questions"
   [{"question" "Which regions were affected, and for how long?"
     "missing_evidence" "INC-9930 records no per-region breakdown and the alert aggregates all regions."
     "citations" [(cite "ticket-9930") (cite "alert-6603")]}]})
