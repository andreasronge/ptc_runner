(ns runtime "Read-only enforced run-resource snapshots." {:visibility :prompt})

(defn usage [] (tool/runtime-usage {}))
(defn remaining [] (tool/runtime-remaining {}))
