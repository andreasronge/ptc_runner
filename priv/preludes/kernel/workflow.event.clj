(ns workflow.event "Bounded workflow-authored semantic annotations." {:visibility :prompt})

(defn annotate
  "Emits one bounded workflow-authored semantic annotation."
  [annotation-type data]
  (tool/workflow-annotate {:type annotation-type :data data}))
