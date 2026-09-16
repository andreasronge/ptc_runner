(ns lab.agent "Calls the compiled tool once. No agent loop, no model." {:visibility :prompt})

(defn- returned-value [outcome]
  (if (= :returned (get outcome :outcome)) (get outcome :value) (fail outcome)))

(defn run [input]
  (return
    (returned-value
      (kernel/eval-with
        "default"
        (program (return (lab.web/quotations (get data/params "url"))))
        {"url" (get input "url")}))))
