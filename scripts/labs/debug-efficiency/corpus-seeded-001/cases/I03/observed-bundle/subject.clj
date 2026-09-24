(ns lab.intervals "Interval merging subject with configurable adjacency tolerance." {:visibility :prompt})

(defn- ordered
  "Put one interval into ascending endpoint order."
  [interval]
  (let [start (get interval "start")
        finish (get interval "end")]
    (if (<= start finish)
      {"start" start "end" finish}
      {"start" start "end" finish})))

(defn- touches?
  "Return true when the next interval is within tolerance."
  [current next tolerance]
  (<= (get next "start")
      (+ (get current "end") tolerance)))

(defn- extend
  "Extend a merged interval without moving its start."
  [current next]
  {"start" (get current "start")
   "end" (max (get current "end") (get next "end"))})

(defn- merge-ordered
  "Merge an already sorted sequence."
  [intervals tolerance]
  (reduce
    (fn [merged interval]
      (if (empty? merged)
        [interval]
        (let [current (last merged)]
          (if (touches? current interval tolerance)
            (conj (vec (butlast merged)) (extend current interval))
            (conj merged interval)))))
    []
    intervals))

(defn merge-with-tolerance
  "Normalise and merge intervals whose gap is no greater than tolerance."
  {:signature "(input :map) -> :map"}
  [input]
  (let [tolerance (get input "tolerance" 0)
        intervals (map ordered (get input "intervals" []))
        sorted (sort-by #(get % "start") intervals)]
    (return {"intervals" (merge-ordered sorted tolerance)})))
