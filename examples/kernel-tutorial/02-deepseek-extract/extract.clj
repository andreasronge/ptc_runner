(ns tutorial.extract "One model request with a structured-output schema." {:visibility :prompt})

(defn extract [input]
  (let [schema {"type" "object"
                "properties" {"project" {"type" "string"}
                              "owner" {"type" "string"}
                              "risk" {"type" "string"}}
                "required" ["project" "owner" "risk"]
                "additionalProperties" false}
        response (llm/request
                   {"system" "Extract the project name, its owner, and the launch risk from the text."
                    "messages" [{"role" "user" "content" (get input "text")}]
                    "schema" schema})]
    (if (= :error (get response :status))
      (fail response)
      (return (get response "structured_output")))))
