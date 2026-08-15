(ns debug.evidence "Immutable primitive navigation over captured run evidence." {:visibility :prompt})

(defn runs
  "List captured runs and return the unwrapped page directly. Example: (debug.evidence/runs {\"status\" \"error\" \"limit\" 5})."
  {:signature "(options :map) -> :map"}
  [options]
  (cap/unwrap! (tool/private-history.runs options)))

(defn open
  "Open one run and return its unwrapped collection catalog directly. Example: (debug.evidence/open \"run-id\")."
  {:signature "(run-id :string) -> :map"}
  [run-id]
  (cap/unwrap! (tool/private-history.open {"run_id" run-id})))

(defn read
  "Read and return one unwrapped native evidence page. Put collection and advertised filters directly in options. Example: (debug.evidence/read \"run-id\" {\"collection\" \"turns\" \"evaluation_id\" \"mission-evaluation-9\"})."
  {:signature "(run-id :string, options :map) -> :map"}
  [run-id options]
  (cap/unwrap! (tool/private-history.read (assoc options "run_id" run-id))))
