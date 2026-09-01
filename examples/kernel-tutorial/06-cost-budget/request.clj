(ns tutorial.cost-budget "Deliberate pre-dispatch cost-budget refusal." {:visibility :prompt})

(defn run [input]
  (let [response
        (tool/llm-request
          {"messages" [{"role" "user" "content" (get input "prompt")}]})]
    (if (= :ok (get response :status))
      (return (get-in response [:value "content"]))
      (fail response))))
