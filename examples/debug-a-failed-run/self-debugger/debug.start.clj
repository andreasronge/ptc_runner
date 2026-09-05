(ns debug.start "Acquire one initial source page for an investigation." {:visibility :prompt})

(defn context
  "Select the latest failed run and follow a complete referenced_prelude_source relationship from its first generated program. Relationship order has no meaning. If no complete source relationship exists, return a context with source nil so the investigator can explain the missing evidence."
  {:signature "() -> :map"}
  []
  (let [run (first (get (debug.nav/runs {"status" "error" "limit" 1}) "items"))
        id (get run "run_id")
        errors (debug.nav/read id {"collection" "execution_errors" "limit" 1})
        generated (first (get (debug.nav/read id {"collection" "generated_sources" "limit" 1}) "items"))
        relationship (first (get generated "relationships"))
        source (when relationship (get (debug.nav/follow id relationship {}) "page"))]
    {"run_id" id "error" (first (get errors "items"))
     "generated" generated "source" source}))
