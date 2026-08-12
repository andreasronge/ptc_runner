(ns inspection.analysis
  "Bounded whole-result traversal for private inspection queries."
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

(defn all-execution-prints
  "Reads one run's execution prints until exhausted or `max-pages` is reached."
  [run-id max-pages]
  (cap/collect-pages
    (fn [cursor] (inspection/execution-prints run-id cursor))
    max-pages))

(defn all-execution-errors
  "Reads one run's execution errors until exhausted or `max-pages` is reached."
  [run-id max-pages]
  (cap/collect-pages
    (fn [cursor] (inspection/execution-errors run-id cursor))
    max-pages))
