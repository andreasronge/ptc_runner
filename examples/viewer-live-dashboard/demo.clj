(ns demo.live "Live dashboard demo: parallel model fan-out, then a synthesis pass." {:visibility :prompt})

(defn ask [topic]
  (let [response (llm/request
                   {"system" "Answer thoroughly in 6 to 8 sentences with an example."
                    "messages" [{"role" "user" "content" topic}]})]
    {"topic" topic
     "answer" (get response "content" "(model error)")}))

(defn run [input]
  (let [topics (get input "topics")
        answers (pmap ask topics)
        summary (llm/request
                  {"system" "Summarize the following Q&A pairs in exactly two sentences."
                   "messages" [{"role" "user" "content" (pr-str answers)}]})]
    (return
      {"answers" answers
       "summary" (get summary "content" "(model error)")})))
