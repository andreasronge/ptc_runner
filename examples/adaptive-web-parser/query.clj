(ns query.workflow "Run the active parser without granting it a model.")

(defn run [input]
  (let [result (kernel/eval-source-with
                 "browser"
                 "(return (demo.browser/query (get data/params \"url\")))"
                 input)]
    (if (= :returned (get result :outcome))
      (return (get result :value))
      (fail result))))
