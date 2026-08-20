(ns triage.rules "Deterministic triage policy for support tickets." {:visibility :prompt})

(defn- sla-minutes [tier]
  (if (= tier "pro") 120 480))

(defn breached?
  "True when the ticket has waited longer than its tier's SLA."
  {:signature "(ticket :map) -> :bool"}
  [ticket]
  (> (get ticket "minutes_open") (sla-minutes (get ticket "tier"))))

(defn priority
  "Priority score from 0 to 100: SLA breach, wait time, and refund risk."
  {:signature "(ticket :map) -> :int"}
  [ticket]
  (let [wait-points (min 30 (quot (get ticket "minutes_open") 60))
        breach-points (if (breached? ticket) 40 0)
        text (str/lower-case (str (get ticket "subject") " " (get ticket "body")))
        refund-points (if (str/includes? text "refund") 20 0)]
    (min 100 (+ 10 wait-points breach-points refund-points))))
