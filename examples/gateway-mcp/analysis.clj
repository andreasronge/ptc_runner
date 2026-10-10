(ns gateway.example)

(defn run {:effect :read} [input]
  (let [result (kernel/eval-source "default" (get input "source"))]
    (if (= :returned (get result :outcome))
      (return {"value" (str (get result :value))})
      (fail result))))
