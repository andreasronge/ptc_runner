(return
  {"status" "report"
   "incident_id" "queue-backlog"
   "summary"
   "From 14:39:12Z on 2026-06-02 the notification consumer group made no forward progress, and undelivered messages reached 412000 against an objective of 5000. Every worker failed on the same unrenderable message, and the backlog drained only after an operator advanced the committed offset past it."
   "timeline"
   [{"observed_at" "2026-06-02T14:38:00Z"
     "statement" "Broker retention for topic notification-events was raised from 24h to 72h."
     "citations" [(cite "config-3310")]}
    {"observed_at" "2026-06-02T14:39:12Z"
     "statement" "notification-consumer workers began exiting with TemplateRenderError for a missing locale field."
     "citations" [(cite "log-22401")]}
    {"observed_at" "2026-06-02T14:41:30Z"
     "statement" "The consumer-lag alert fired at 412000 undelivered messages."
     "citations" [(cite "alert-9012")]}
    {"observed_at" "2026-06-02T14:52:00Z"
     "statement" "Message 8831f4 had been redelivered 214 times, each attempt ending in the same error."
     "citations" [(cite "log-22890")]}
    {"observed_at" "2026-06-02T17:09:40Z"
     "statement" "An operator advanced the committed offset past message 8831f4 and consumers resumed forward progress."
     "citations" [(cite "log-24115")]}]
   "observed_facts"
   [{"statement" "Consumer lag for notify-workers reached 412000 undelivered messages against an objective of 5000."
     "citations" [(cite "alert-9012")]}
    {"statement" "notification-consumer workers exited non-zero with TemplateRenderError for a missing 'locale' field from 14:39:12Z, and were restarted by the supervisor."
     "citations" [(cite "log-22401")]}
    {"statement" "Message 8831f4 was redelivered 214 times between 14:39:12Z and 14:52:00Z, and no dead-letter destination is configured for topic notification-events."
     "citations" [(cite "log-22890")]}
    {"statement" "The retention change altered on-disk retention only, and the change record states it does not alter consumer concurrency, acknowledgement behaviour, or delivery order."
     "citations" [(cite "config-3310")]}
    {"statement" "Scaling notify-workers from 6 to 24 replicas did not change the lag, and every worker crash-looped on the same message."
     "citations" [(cite "chat-4418") (cite "chat-4436")]}
    {"statement" "Release 4.19.0, deployed twenty-seven hours before the incident, added a template renderer that raises TemplateRenderError when a payload's locale field is absent."
     "citations" [(cite "deploy-3311")]}
    {"statement" "The backlog drained below objective at 17:12:04Z, after the committed offset was advanced at 17:09:40Z."
     "citations" [(cite "log-24115")]}]
   "hypotheses"
   [{"statement" "A single unrenderable message at the head of its partition blocked forward progress for the whole consumer group."
     "confidence" "high"
     "supporting_citations"
     [(cite "log-22401") (cite "log-22890") (cite "chat-4436") (cite "log-24115")]
     "contradicting_citations" []}
    {"statement" "The broker retention configuration change caused the backlog."
     "confidence" "low"
     "supporting_citations" [(cite "chat-4410")]
     "contradicting_citations" [(cite "config-3310") (cite "chat-4436")]}
    {"statement" "Under-provisioned consumers caused the backlog."
     "confidence" "low"
     "supporting_citations" [(cite "chat-4418")]
     "contradicting_citations" [(cite "chat-4436")]}]
   "open_questions"
   [{"question" "Which producer emitted an order_shipped payload with no locale field, and are further such payloads queued?"
     "missing_evidence" "The incident channel records that this was never established after the offset was advanced."
     "citations" [(cite "chat-4460")]}
    {"question" "How quickly did the backlog grow between 14:39Z and 16:00Z?"
     "missing_evidence" "The consumer-lag series is retained for 90 minutes and has no samples before 16:00:00Z."
     "citations" [(cite "metric-lag-window")]}
    {"question" "How many customer notifications were delayed or dropped?"
     "missing_evidence" "INC-8815 records no estimate of delayed or dropped notifications and none was added before resolution."
     "citations" [(cite "ticket-8815")]}]})
