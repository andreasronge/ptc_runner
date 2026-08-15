(ns debug.workspace
  "Read-only frozen working-set context for an incident whose retained evidence may not distinguish one faulty component. Presence in the working set is not evidence of fault."
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
  "Return the exact captured sources in this experiment's working set. The caller must still establish causality and abstain when evidence does not distinguish a repair."
  {:signature "(run-id :string, generated-sources [:map]) -> :map"}
  [run-id _generated-sources]
  (let [pages (mapv #(source run-id %) ["pricing.base" "pricing.tax" "orders"])]
    {"complete?" true
     "files"
     (mapv
       #(select-keys % ["component_id" "environment" "mission_name"
                        "source_hash" "source"])
       (mapcat #(get % "items") pages))}))
