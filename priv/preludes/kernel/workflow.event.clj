(ns workflow.event "Bounded workflow-authored semantic annotations." {:visibility :prompt})

(defn annotate
  "Emits one bounded workflow-authored semantic annotation.

  A refused well-formed annotation — a string type or data shape that is
  not in the traces vocabulary — returns {:status :error :kind
  :invalid_annotation :reason :invalid_workflow_annotation} rather than
  failing the evaluation. Accepted types and keys are the finite vocabulary
  published by ptc docs traces."
  [annotation-type data]
  (tool/workflow-annotate {:type annotation-type :data data}))
