(ns tutorial.fan-out "Parallel model fan-out, then one synthesis call." {:visibility :prompt})

(defn ask
  "Ask one topic. Returns the answer, or the provider's error envelope."
  [topic]
  (let [response (llm/request
                   {"system" "Answer thoroughly in 6 to 8 sentences with an example."
                    "messages" [{"role" "user" "content" topic}]})]
    (if (= :error (get response :status))
      response
      {"topic" topic
       "answer" (get response "content")})))

(defn run [input]
  (let [answers (pmap ask (get input "topics"))
        failed (filter #(= :error (get % :status)) answers)]
    (if (seq failed)
      (fail (first failed))
      (let [summary (llm/request
                      {"system" "Summarize the following question and answer pairs in exactly two sentences."
                       "messages" [{"role" "user" "content" (pr-str answers)}]})]
        (if (= :error (get summary :status))
          (fail summary)
          (return
            {"answers" answers
             "summary" (get summary "content")}))))))
