(ns repair.validation
  "Deterministic workflow for host-owned candidate behavior checks.")

(defn run [input]
  (let [evaluation
        (kernel/eval-with
          "default"
          (program (return (orders/place (get data/params "subtotal"))))
          {"subtotal" (get input "subtotal")})]
    (if (= :returned (get evaluation :outcome))
      (return (get evaluation :value))
      (fail (or (get evaluation :value) "candidate evaluation failed")))))
