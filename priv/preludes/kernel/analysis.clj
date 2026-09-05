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
  "Reads one bounded page from a captured run-evidence collection. Put collection, limit, cursor, and the selected collection's advertised filters directly in options; do not nest them under filters. Call analysis/open first to discover the accepted filters for each collection."
  [run-id options]
  (cap/unwrap! (tool/analysis-read (assoc options "run_id" run-id))))

(defn counters
  "Returns trace counters for a filtered run cohort, including adapter-attested model usage. Accepted keys are status, run_id, trace_id, tags, name, bundle, model, provider, from, to, and mission_name; there is no limit, cursor, view, or run_ids argument. Example: (analysis/counters {\"run_id\" \"cmd-...\"}). Call once per selected run_id to reduce an explicit cohort."
  [filters]
  (cap/unwrap! (tool/analysis-counters filters)))
