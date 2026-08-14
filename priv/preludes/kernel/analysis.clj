(ns analysis "Bounded navigation over one immutable run-evidence capture." {:visibility :prompt})

(defn runs [options] (cap/unwrap! (tool/analysis-runs options)))
(defn open [run-id] (cap/unwrap! (tool/analysis-open {"run_id" run-id})))
(defn read [run-id options]
  (cap/unwrap! (tool/analysis-read (assoc options "run_id" run-id))))
