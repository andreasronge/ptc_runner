(ns gateway.example)

(defn run {:effect :write} [input]
  (let [result (agent.core/run-value "Call (files/briefs) and return its exact string unchanged." {"max_turns" 4})]
    (return {"value" result})))
