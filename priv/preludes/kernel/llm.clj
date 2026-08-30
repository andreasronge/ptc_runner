(ns llm "Provider-neutral language-model requests." {:visibility :prompt})

(defn request
  "Send a provider-neutral request. An optional schema key requests
  structured output: success is a structured_output object with optional
  tokens, never encoded content. Tools and schema together are invalid.
  Tool calls use id, name, and args; token usage may include input, output,
  cache_creation, cache_read, and fixed-point total_cost as a USD currency and
  integer microunits object.

  On success this returns the model response value. Provider failures,
  including a replay miss, are returned as error envelopes with :status
  :error rather than failing the evaluation. Branch on :status and fail, or
  call cap/unwrap! on the raw tool/llm-request envelope, so an unserved call
  cannot look like a result."
  [request]
  (let [response (tool/llm-request request)]
    (if (= :ok (get response :status))
      (get response :value)
      response)))
