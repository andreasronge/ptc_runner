(ns decision
  "Provider-neutral requests to an installed decision-model capability."
  {:visibility :prompt})

(defn request
  "Evaluate named choice, score, or boolean questions against state.

  On success this returns the normalized decision response. Boolean value is
  optional and may be true, false, or nil; false is a supplied answer. Missing
  probability is unavailable measurement, not low confidence. Choose whether
  to use a discrete answer or abstain/escalate when measurements are required. Provider failures
  remain error envelopes with :status :error so the caller can branch or fail
  explicitly."
  [request]
  (let [response (tool/decision-request request)]
    (if (= :ok (get response :status))
      (get response :value)
      response)))
