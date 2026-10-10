(ns gateway.example)

(defn run {:effect :read} [input]
  (let [result (kernel/eval-source "default" "(return (files/briefs))")]
    (if (= :returned (get result :outcome))
      (return {"value" (get result :value)})
      (fail result))))
