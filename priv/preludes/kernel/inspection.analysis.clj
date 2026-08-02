(ns inspection.analysis
  "Bounded whole-result traversal for private inspection queries, plus shape
  conveniences built on that traversal layer (see `prose` below)."
  {:visibility :discoverable})

(defn all-runs
  "Reads inspection-run pages until exhausted or `max-pages` is reached."
  [options max-pages]
  (cap/collect-pages
    (fn [cursor]
      (inspection/runs (cap/with-cursor options cursor)))
    max-pages))

(defn all-model-exchanges
  "Reads one run's model exchanges until exhausted or `max-pages` is reached."
  [run-id max-pages]
  (cap/collect-pages
    (fn [cursor] (inspection/model-exchanges run-id cursor))
    max-pages))

(defn all-capability-calls
  "Reads one run's capability calls until exhausted or `max-pages` is reached."
  [run-id max-pages]
  (cap/collect-pages
    (fn [cursor] (inspection/capability-calls run-id cursor))
    max-pages))

(defn all-generated-sources
  "Reads one run's generated sources until exhausted or `max-pages` is reached."
  [run-id max-pages]
  (cap/collect-pages
    (fn [cursor] (inspection/generated-sources run-id cursor))
    max-pages))

(defn all-effective-preludes
  "Reads one run's effective preludes until exhausted or `max-pages` is reached."
  [run-id max-pages]
  (cap/collect-pages
    (fn [cursor] (inspection/effective-preludes run-id cursor))
    max-pages))

(defn all-provider-exchanges
  "Reads one run's provider exchanges until exhausted or `max-pages` is reached."
  [run-id max-pages]
  (cap/collect-pages
    (fn [cursor] (inspection/provider-exchanges run-id cursor))
    max-pages))

(defn prose
  "Reads the model's own narration per turn, exhausting pages up to
  `max-pages`.

  Each item is `{\"evaluation_id\" ... \"content\" ...}`, built from
  `all-model-exchanges` in turn order: `evaluation_id` correlates the
  narration to the same turn as capability calls and annotations, and
  `content` is read from `[\"result\" \"value\" \"content\"]` on the
  exchange. The result keeps `all-model-exchanges`'
  `complete?`/`pages`/`snapshot_hash` envelope around the projected `items`."
  [run-id max-pages]
  (let [page (all-model-exchanges run-id max-pages)
        narrate (fn [exchange]
                  {"evaluation_id" (get exchange "evaluation_id")
                   "content" (get-in exchange ["result" "value" "content"])})]
    (assoc page "items" (mapv narrate (get page "items")))))
