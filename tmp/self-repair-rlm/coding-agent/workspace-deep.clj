(ns debug.workspace
  "Read-only frozen working-set context for the unrelated functional-failure comparison. Presence in the working set is not evidence of fault."
  {:visibility :prompt})

(defn- source [run-id component-id]
  (debug.nav/read
    run-id
    {"collection" "prelude_sources"
     "environment" "mission"
     "mission_name" "default"
     "component_id" component-id
     "limit" 10}))

(defn changed
  "Return the exact captured sources in this experiment's working set. The caller must still establish causality from run evidence."
  {:signature "(run-id :string, generated-sources [:map]) -> :map"}
  [run-id _generated-sources]
  (let [pages (mapv #(source run-id %)
                    ["pricing.rule" "pricing.tax" "pricing.discount" "orders"])]
    {"complete?" true
     "files"
     (mapv
       #(select-keys % ["component_id" "environment" "mission_name"
                        "source_hash" "source"])
       (mapcat #(get % "items") pages))}))
