(ns workflow.event "Bounded workflow-authored semantic annotations." {:visibility :prompt})

(defn annotate [annotation-type data]
  (tool/workflow-annotate {:type annotation-type :data data}))
