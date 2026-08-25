(ns analysis "Bounded navigation over one immutable run-evidence capture." {:visibility :prompt})

(defn runs
  "Lists captured runs using the stable run-analysis profile."
  [options]
  (cap/unwrap! (tool/analysis-runs options)))

(defn open
  "Opens one captured run and returns its available evidence collections."
  [run-id]
  (cap/unwrap! (tool/analysis-open {"run_id" run-id})))

(defn read
  "Reads one bounded page from a captured run-evidence collection."
  [run-id options]
  (cap/unwrap! (tool/analysis-read (assoc options "run_id" run-id))))

(defn counters
  "Returns canonical trace counters for a filtered run cohort, including adapter-attested model usage. Filters are the existing counter keys; there is no limit, cursor, view, or run_ids argument. Call once per selected run_id to reduce an explicit cohort."
  [filters]
  (cap/unwrap! (tool/analysis-counters filters)))
