(ns example.decision)

(defn run [request]
  (let [response (decision/request request)]
    (if (= :error (get response :status))
      (fail response)
      (let [answers (get response "answers")
            tickets (get-in request ["state" "tickets"])]
        (return
          {"refund_ticket_ids"
           (->> tickets
                (filter (fn [ticket]
                          (>= (get-in answers [(str "T_" (subs (get ticket "id") 2)) "probability"]) 0.5)))
                (map (fn [ticket] (get ticket "id")))
                vec)
           "decisions" answers
           "model" (get response "model")
           "usage" (get response "usage")})))))
