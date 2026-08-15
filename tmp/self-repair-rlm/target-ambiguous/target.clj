(ns target
  "Host validation entry for the ambiguous repair fixture."
  {:visibility :prompt})

(defn run [input]
  (let [evaluation
        (kernel/eval-with
          "default"
          (program
            (return (orders/place (get data/params "subtotal"))))
          {"subtotal" (get input "subtotal")})]
    (if (= :returned (get evaluation :outcome))
      (return (get evaluation :value))
      (fail (get evaluation :value)))))
