;; Scripted defect: the second observed fact asserts a customer-impact number
;; that no record states, and carries no citation. The result contract rejects
;; it while a correction turn is still available.
(return
  {"status" "report"
   "incident_id" "checkout-5xx"
   "summary" "Checkout submissions failed with 502 responses for roughly 46 minutes."
   "timeline"
   [{"observed_at" "2026-05-14T09:11:47Z"
     "statement" "Payments-connector TLS handshakes to payments-gateway.internal began failing with an expired certificate."
     "citations" [(cite "log-88120")]}
    {"observed_at" "2026-05-14T09:12:03Z"
     "statement" "The checkout-api error-ratio alert fired."
     "citations" [(cite "alert-4471")]}]
   "observed_facts"
   [{"statement" "The checkout error-ratio alert reported a 5xx ratio of 0.184 against an objective of 0.005."
     "citations" [(cite "alert-4471")]}
    {"statement" "Approximately 12000 customers were unable to complete checkout."
     "citations" []}]
   "hypotheses"
   [{"statement" "The expired payments-gateway leaf certificate caused the checkout failures."
     "confidence" "high"
     "supporting_citations" [(cite "log-88120") (cite "chat-1204")]}]
   "open_questions" []})
