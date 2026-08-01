(ns log.analysis
  "Bounded whole-result traversal for canonical trace queries."
  {:visibility :prompt})

(defn all-runs
  "Reads run pages until the source is exhausted or `max-pages` is reached."
  [options max-pages]
  (cap/collect-pages
    (fn [cursor] (log/runs (cap/with-cursor options cursor)))
    max-pages))

(defn all-turns
  "Reads one run's turn pages until exhausted or `max-pages` is reached."
  [run-id options max-pages]
  (cap/collect-pages
    (fn [cursor]
      (log/turns run-id (cap/with-cursor options cursor)))
    max-pages))
