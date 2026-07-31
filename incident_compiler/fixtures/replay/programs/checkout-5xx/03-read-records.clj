(def evidence-ids
  ["alert-4471" "alert-4472" "chat-1180" "chat-1186" "chat-1204"
   "deploy-2291" "deploy-2292" "log-88120" "log-88455" "log-90013"
   "ticket-7742" "ticket-7749" "trace-5f21"])

(def records
  (reduce
    (fn [acc id]
      (assoc acc id (get (incident.evidence/get-record "checkout-5xx" id) "record")))
    {}
    evidence-ids))

(defn cite [id]
  {"evidence_id" id "content_digest" (get (get records id) "content_digest")})

(count records)
