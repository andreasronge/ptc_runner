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

(defn mission-inventory
  "Return the exact frozen model-visible mission inventory JSON."
  []
  (let [response (tool/kernel-mission-inventory {})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn mission-model-context
  "Return the compact deterministic mission context for the model prompt."
  []
  (let [response (tool/kernel-mission-model-context {})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))
