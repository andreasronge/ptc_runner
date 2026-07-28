(ns llm "Provider-neutral language-model requests." {:visibility :prompt})

(defn request
  "Send a provider-neutral request. Tool calls use id, name, and args; token
  usage may include input, output, cache_creation, cache_read, and total_cost."
  [request]
  (let [response (tool/llm-request request)]
    (if (= :ok (get response :status))
      (get response :value)
      response)))
