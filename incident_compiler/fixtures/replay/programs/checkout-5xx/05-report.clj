;; Correction turn: the uncited customer-impact number is withdrawn from
;; observed facts and reappears as an open question naming the record that
;; would have answered it.
(return
  {"status" "report"
   "incident_id" "checkout-5xx"
   "summary"
   "Between 09:11:47Z and 09:57:55Z on 2026-05-14, POST /v2/checkout/submit returned 502 upstream_unavailable at a rate far above its objective. The failures coincide with expired-certificate TLS handshake failures from the payments connector to payments-gateway.internal, and recovery coincides with that certificate's rotation rather than with the rollback."
   "timeline"
   [{"observed_at" "2026-05-14T09:09:52Z"
     "statement" "Release 2026.5.14-a was deployed to checkout-api."
     "citations" [(cite "deploy-2291")]}
    {"observed_at" "2026-05-14T09:11:47Z"
     "statement" "Payments-connector TLS handshakes to payments-gateway.internal began failing with an expired certificate."
     "citations" [(cite "log-88120")]}
    {"observed_at" "2026-05-14T09:12:02Z"
     "statement" "POST /v2/checkout/submit began returning 502 upstream_unavailable after the connector exhausted its retries."
     "citations" [(cite "log-88455")]}
    {"observed_at" "2026-05-14T09:12:03Z"
     "statement" "The checkout-api error-ratio alert fired."
     "citations" [(cite "alert-4471")]}
    {"observed_at" "2026-05-14T09:57:55Z"
     "statement" "Payments-connector TLS handshakes succeeded again and the error rate returned to baseline."
     "citations" [(cite "log-90013")]}
    {"observed_at" "2026-05-14T10:04:18Z"
     "statement" "The rollback to 2026.5.13-c completed."
     "citations" [(cite "deploy-2292")]}]
   "observed_facts"
   [{"statement" "The checkout error-ratio alert reported a 5xx ratio of 0.184 over five minutes against an objective of 0.005."
     "citations" [(cite "alert-4471")]}
    {"statement" "Outbound TLS handshakes from the payments connector failed with 'certificate has expired' from 09:11:47Z, sustained at 40 to 60 events per second."
     "citations" [(cite "log-88120")]}
    {"statement" "The changes recorded for release 2026.5.14-a are checkout confirmation email templates and a CSV export dependency, neither of which the release record places on the submit path."
     "citations" [(cite "deploy-2291")]}
    {"statement" "The 5xx ratio returned to 0.004 at 09:58:10Z, six minutes before the rollback completed at 10:04:18Z."
     "citations" [(cite "deploy-2292")]}
    {"statement" "A sampled failing request spent 10388ms in the payments.authorize span and recorded no upstream response, and entered neither the email template nor the CSV export code path."
     "citations" [(cite "trace-5f21")]}
    {"statement" "The payments-gateway team reported that the leaf certificate for payments-gateway.internal expired at 09:11:40Z and that its replacement took effect at 09:57:50Z."
     "citations" [(cite "chat-1204")]}
    {"statement" "The reported p99 latency of 10400ms equals the configured client timeout, which the alert record describes as a ceiling rather than a measured completion time."
     "citations" [(cite "alert-4472")]}]
   "hypotheses"
   [{"statement" "The expired payments-gateway leaf certificate caused the checkout 5xx spike."
     "confidence" "high"
     "supporting_citations"
     [(cite "log-88120") (cite "chat-1204") (cite "log-90013") (cite "trace-5f21")]
     "contradicting_citations" []}
    {"statement" "Release 2026.5.14-a caused the checkout 5xx spike."
     "confidence" "low"
     "supporting_citations" [(cite "chat-1180")]
     "contradicting_citations" [(cite "deploy-2291") (cite "deploy-2292") (cite "trace-5f21")]}]
   "open_questions"
   [{"question" "How many customers were unable to complete a checkout during the incident?"
     "missing_evidence" "INC-7742 left its impact field empty and no customer-impact estimate was recorded before resolution."
     "citations" [(cite "ticket-7742")]}
    {"question" "Which team owns renewal automation for the payments-gateway.internal certificate?"
     "missing_evidence" "The payments-gateway team reported having no record of an owner for that host's renewal automation."
     "citations" [(cite "chat-1204")]}
    {"question" "Why does the resolution note attribute recovery to the rollback?"
     "missing_evidence" "The INC-7742 resolution note records only 'rolled back and recovered' and does not mention the certificate rotation reported in the incident channel."
     "citations" [(cite "ticket-7749")]}]})
