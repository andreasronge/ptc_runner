(ns log "Source-scoped canonical trace queries." {:visibility :prompt})

(defn- unwrap [response]
  (if (= :ok (get response :status))
    (get response :value)
    response))

(defn runs [options] (unwrap (tool/trace-list-runs options)))
(defn run [run-id] (unwrap (tool/trace-get-run {"run_id" run-id})))
(defn turns [run-id options]
  (unwrap (tool/trace-list-turns (assoc options "run_id" run-id))))
(defn counters [options] (unwrap (tool/trace-counters options)))
