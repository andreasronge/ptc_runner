(ns lab.compiler "Discovers one recipe and proves it on a held-out page." {:visibility :prompt})

(defn run [input]
  (agent.core/run
    (str "Find one extraction recipe that works on both pages.\n\n"
         "Learn page: " (get input "learn_url") "\n"
         "Held-out page: " (get input "holdout_url") "\n\n"
         "The two pages carry different markup for the same kind of record. "
         "Read each page's text first so you know which records it contains, "
         "then use lab.probe/try-recipes to test MANY candidate selectors in one "
         "call, because each call costs one page load. Keep going until the "
         "extracted records match what you read, on BOTH pages. "
         "Boilerplate such as navigation must not appear in the records.\n\n"
         "Return {\"container\": ..., \"text_selector\": ..., \"author_selector\": ...}.")
    {"max_turns" 20 "result_envelope" false}))
