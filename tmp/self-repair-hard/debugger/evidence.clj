(ns debug.evidence "Immutable navigation over captured run evidence." {:visibility :prompt})

(defn runs
  "List captured runs."
  {:signature "(options :map) -> :map"}
  [options]
  (cap/unwrap! (tool/private-history.runs options)))

(defn open
  "Open one run and discover its collections, filters, relationships, and capture metadata."
  {:signature "(run-id :string) -> :map"}
  [run-id]
  (cap/unwrap! (tool/private-history.open {"run_id" run-id})))

(defn read
  "Read one bounded collection page. Put collection and advertised filters directly in options."
  {:signature "(run-id :string, options :map) -> :map"}
  [run-id options]
  (cap/unwrap! (tool/private-history.read (assoc options "run_id" run-id))))
