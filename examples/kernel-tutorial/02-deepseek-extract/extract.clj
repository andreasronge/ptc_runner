(ns tutorial.extract "One bounded provider-neutral model request." {:visibility :prompt})

(defn extract [input]
  (let [text (get input "text")
        response
        (tool/llm-request
          {"system" (str "Extract project metadata. Reply with exactly one compact JSON "
                         "object with string keys project, owner, and risk. Use null when "
                         "the text does not provide a value. Do not use Markdown.")
           "messages" [{"role" "user" "content" text}]})]
    (if (= :ok (get response :status))
      (return
        {"model_output" (get-in response [:value "content"])
         "note" "model_output is model text; validate or parse it before production use"})
      (fail
        {"kind" "llm-provider-error"
         "provider_response" response}))))
