(ns analysis "Question-shaped reads over one immutable run-evidence capture." {:visibility :prompt})

(defn runs [options] (cap/unwrap! (tool/analysis-runs options)))
(defn overview [run-id] (cap/unwrap! (tool/analysis-overview {"run_id" run-id})))
(defn activity [run-id options]
  (cap/unwrap! (tool/analysis-activity (assoc options "run_id" run-id))))
(defn conversation [run-id options]
  (cap/unwrap! (tool/analysis-conversation (assoc options "run_id" run-id))))
(defn failure [run-id options]
  (cap/unwrap! (tool/analysis-failure (assoc options "run_id" run-id))))
(defn source [run-id options]
  (cap/unwrap! (tool/analysis-source (assoc options "run_id" run-id))))
