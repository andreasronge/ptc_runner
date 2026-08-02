(ns log.analysis
  "Bounded whole-result traversal for canonical trace queries, plus shape
  conveniences built on that traversal layer (see `annotations` below)."
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

(defn annotations
  "Reads a run's workflow annotations, exhausting pages up to `max-pages`.

  Each item is one annotation event's `data` map — `annotation_type`, `data`
  (the payload), `provenance`, and `evaluation_id` — with the outer
  `{\"type\" ... \"data\" ...}` event envelope stripped. `type` selects one
  `annotation_type`, passed through as a `log/turns` filter so the source does
  the filtering; nil returns every annotation for the run. The result keeps
  `all-turns`' `complete?`/`pages`/`snapshot_hash` envelope around the
  filtered `items`."
  [run-id type max-pages]
  (let [query (if (nil? type) {} {"annotation_type" type})
        page (all-turns run-id query max-pages)
        matched (filterv #(= "workflow-annotation" (get % "type")) (get page "items"))]
    (assoc page "items" (mapv #(get % "data") matched))))
