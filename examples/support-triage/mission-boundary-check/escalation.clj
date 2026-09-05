(ns escalation.policy "Routing policy for escalated tickets." {:visibility :prompt})

(defn team-for
  "Owning team for a ticket category: billing, incident, or account."
  {:signature "(category :string) -> :string"}
  [category]
  (cond
    (= category "billing") "payments"
    (= category "incident") "sre"
    :else "support"))

(defn first-action
  "Required first action when escalating a ticket of this category and tier."
  {:signature "(category :string, tier :string) -> :string"}
  [category tier]
  (cond
    (= category "incident") "page the on-call engineer"
    (and (= category "billing") (= tier "pro")) "verify the charge with finance before replying"
    (= category "billing") "send the refund-policy summary"
    :else "reply with the account-recovery checklist"))
