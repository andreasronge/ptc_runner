(ns log "Source-scoped canonical trace queries." {:visibility :prompt})

(defn runs [options] (cap/unwrap! (tool/trace-list-runs options)))
(defn run [run-id] (cap/unwrap! (tool/trace-get-run {"run_id" run-id})))
(defn turns [run-id options]
  (cap/unwrap! (tool/trace-list-turns (assoc options "run_id" run-id))))
(defn counters [options] (cap/unwrap! (tool/trace-counters options)))
