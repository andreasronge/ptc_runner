(ns target "Deterministic validation entry for the delivery fixture." {:visibility :prompt})

(defn run [input]
  (let [evaluation
        (kernel/eval-with
          "default"
          (program
            (return
              (delivery/quote
                {"grams" (get data/params "grams")
                 "destination" "local"})))
          {"grams" (get input "grams")})]
    (if (= :returned (get evaluation :outcome))
      (return (get evaluation :value))
      (fail (get evaluation :value)))))
