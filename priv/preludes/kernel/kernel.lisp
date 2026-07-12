(ns kernel "Explicit subordinate evaluation helpers." {:visibility :prompt})

(defn eval
  "Evaluate an opaque static Program in the mission environment."
  [program-value]
  (let [response (tool/kernel-eval {:kind :embedded :program program-value})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn eval-source
  "Evaluate bounded dynamic source text in the mission environment."
  [source]
  (let [response (tool/kernel-eval {:kind :source :source source})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))
