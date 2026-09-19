(ns decision
  "Provider-neutral requests to an installed decision-model capability."
  {:visibility :prompt})

(defn request
  "Evaluate named choice, score, or boolean questions against state.

  On success this returns the normalized decision response. Provider failures
  remain error envelopes with :status :error so the caller can branch or fail
  explicitly."
  [request]
  (let [response (tool/decision-request request)]
    (if (= :ok (get response :status))
      (get response :value)
      response)))
