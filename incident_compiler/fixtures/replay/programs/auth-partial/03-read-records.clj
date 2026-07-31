(def evidence-ids
  ["alert-6603" "chat-2201" "chat-2209" "chat-2231" "chat-2258"
   "deploy-4402" "log-31200" "log-31488" "maint-0091" "ticket-9930"
   "ticket-9941" "trace-9c40"])

(def records
  (reduce
    (fn [acc id]
      (assoc acc id (get (incident.evidence/get-record "auth-partial" id) "record")))
    {}
    evidence-ids))

(defn cite [id]
  {"evidence_id" id "content_digest" (get (get records id) "content_digest")})

(count records)
