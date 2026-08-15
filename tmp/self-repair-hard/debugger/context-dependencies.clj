(ns debug.context "Coarse incident context assembled from immutable run evidence." {:visibility :prompt})

(defn- direct-dependencies
  [run called-components]
  (mapcat
    (fn [mission]
      (let [prelude (get mission "prelude")
            component-ids (get prelude "component_ids")
            dependency-indices (get prelude "dependency_indices")]
        (mapcat
          (fn [called]
            (let [matches
                  (filter
                    (fn [index] (= (nth component-ids index) called))
                    (range (count component-ids)))
                  index (first matches)]
              (if index
                (map
                  (fn [dependency-index]
                    (nth component-ids dependency-index))
                  (nth dependency-indices index))
                [])))
          called-components)))
    (vals (get run "missions"))))

(defn latest-failure
  "Return one latest failed run with errors, turns, and sources for called components plus their immediate dependencies."
  {:signature "(options :map) -> :map"}
  [options]
  (let [listing (cap/unwrap!
                  (tool/private-history.runs
                    (assoc options "status" "error" "limit" 1)))
        run (first (get listing "items"))
        run-id (get run "run_id")]
    (if run-id
      (let [errors (cap/unwrap!
                     (tool/private-history.read
                       {"run_id" run-id
                        "collection" "execution_errors"
                        "limit" 20}))
            turns (cap/unwrap!
                    (tool/private-history.read
                      {"run_id" run-id
                       "collection" "turns"
                       "limit" 20}))
            called-components
            (distinct
              (mapcat
                (fn [turn]
                  (mapcat
                    (fn [generated]
                      (map
                        (fn [call] (get call "component_id"))
                        (get generated "prelude_calls")))
                    (get turn "generated")))
                (get turns "items")))
            dependency-components
            (distinct (direct-dependencies run called-components))
            related-components
            (distinct (concat called-components dependency-components))
            sources
            (mapcat
              (fn [component-id]
                (get
                  (cap/unwrap!
                    (tool/private-history.read
                      {"run_id" run-id
                       "collection" "prelude_sources"
                       "component_id" component-id
                       "limit" 20}))
                  "items"))
              related-components)]
        {"run" run
         "execution_errors" (get errors "items")
         "turns" (get turns "items")
         "called_components" called-components
         "dependency_components" dependency-components
         "prelude_sources" sources})
      (fail "no failed run is available in the immutable capture"))))
