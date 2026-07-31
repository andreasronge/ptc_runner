(def evidence-ids
  ["alert-9012" "chat-4410" "chat-4418" "chat-4436" "chat-4460"
   "config-3310" "deploy-3311" "log-22401" "log-22890" "log-24115"
   "metric-lag-window" "ticket-8815"])

(def records
  (reduce
    (fn [acc id]
      (assoc acc id (get (incident.evidence/get-record "queue-backlog" id) "record")))
    {}
    evidence-ids))

(defn cite [id]
  {"evidence_id" id "content_digest" (get (get records id) "content_digest")})

(count records)
