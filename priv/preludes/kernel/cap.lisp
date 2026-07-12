(ns cap "Environment-local capability discovery." {:visibility :prompt})

(defn list [] (tool/cap-list {}))
(defn describe [name] (tool/cap-describe {:name name}))
