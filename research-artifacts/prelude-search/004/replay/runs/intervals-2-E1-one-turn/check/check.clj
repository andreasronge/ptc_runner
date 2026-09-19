(ns lab.check "Recorded candidate selection and final evaluation.")
(defn- check [candidate cases source]
  (if (get candidate "valid")
    (every? true?
      (mapv (fn [row]
        (let [result (kernel/eval-source-with (get candidate "mission") source (get row "input"))]
          (and (= :returned (get result :outcome)) (= (get row "oracle") (get result :value))))) cases))
    false))
(defn run [input]
  (let [checked (mapv (fn [candidate]
                   (assoc candidate "passed" (check candidate (get input "selection") (get input "program"))))
                 (get input "candidates"))
        selected (first (filter #(get % "passed") checked))
        final-pass (if selected (check selected (get input "final") (get input "program")) false)]
    (return {"selection" checked "selected" (get selected "index") "final_pass" final-pass})))
