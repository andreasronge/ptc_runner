(ns debug.context "Coarse incident context assembled from immutable run evidence." {:visibility :prompt})

(defn latest-failure
  "Return one latest failed run with its execution errors, reconstructed turns, and captured prelude sources."
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
              called-components)]
        {"run" run
         "execution_errors" (get errors "items")
         "turns" (get turns "items")
         "called_components" called-components
         "prelude_sources" sources})
      (fail "no failed run is available in the immutable capture"))))
