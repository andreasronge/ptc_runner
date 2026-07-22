(ns llm "Provider-neutral language-model requests." {:visibility :prompt})

(defn request [request]
  (let [response (tool/llm-request request)]
    (if (= :ok (get response :status))
      (get response :value)
      response)))
