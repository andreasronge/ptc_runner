(ns debug.workspace
  "Read-only frozen working-set context for the coding-agent comparison. Presence in the working set is not evidence of fault."
  {:visibility :prompt})

(defn changed
  "Return the exact captured sources that were being changed for this experiment. The caller must still establish causality from run evidence."
  {:signature "(run-id :string) -> :map"}
  [run-id]
  (let [workflow
        (debug.nav/read
          run-id
          {"collection" "prelude_sources"
           "environment" "workflow"
           "component_id" "debug.rlm.workflow"
           "limit" 10})
        delegate
        (debug.nav/read
          run-id
          {"collection" "prelude_sources"
           "environment" "mission"
           "mission_name" "root"
           "component_id" "debug.rlm"
           "limit" 10})]
    {"files"
     (mapv
       #(select-keys % ["component_id" "environment" "mission_name"
                        "source_hash" "source"])
       (concat (get workflow "items") (get delegate "items")))}))
