(ns agent.retry "Small deterministic agent retry policy." {:visibility :prompt})

(defn retry? [turn max-turns]
  (< (inc turn) max-turns))

(defn backoff-ms [turn cfg]
  (let [base (or (get cfg "retry_backoff_ms") 0)
        ceiling (or (get cfg "retry_backoff_max_ms") base)]
    (min ceiling (* base (inc turn)))))
