(ns analysis "Bounded discovery over one immutable private run-catalog generation." {:visibility :prompt})

(defn catalog
  "Pages and filters the frozen safe-metadata rows in this catalog generation."
  [query]
  (cap/unwrap! (tool/analysis-catalog query)))
