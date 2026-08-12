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

(defn eval-with
  "Evaluate an opaque static Program with JSON parameters at data/params."
  [program-value params]
  (let [response (tool/kernel-eval {:kind :embedded
                                    :program program-value
                                    :params params})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn eval-source-with
  "Evaluate bounded dynamic source with JSON parameters at data/params."
  [source params]
  (let [response (tool/kernel-eval {:kind :source
                                    :source source
                                    :params params})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn eval-source-in
  "Evaluate bounded dynamic source text in the named mission."
  [mission source]
  (let [response (tool/kernel-eval {:kind :source :source source :mission mission})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn eval-source-with-in
  "Evaluate bounded dynamic source in the named mission with JSON parameters."
  [mission source params]
  (let [response (tool/kernel-eval {:kind :source
                                    :source source
                                    :params params
                                    :mission mission})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn mission-model-context-in
  "Return the compact deterministic context for one named mission."
  [mission]
  (let [response (tool/kernel-mission-model-context {:mission mission})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn check-source
  "Check bounded dynamic source against the live mission environment without executing it."
  [source]
  (let [response (tool/kernel-check-source {:source source})]
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

(defn mission-inventory-in
  "Return the exact frozen model-visible inventory for one named mission."
  [mission]
  (let [response (tool/kernel-mission-inventory {:mission mission})]
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

(defn validate-result
  "Validate one candidate against the manifest's application result contract."
  [value]
  (let [response (tool/kernel-result-contract {"value" value})]
    (if (= :ok (get response :status))
      (get response :value)
      (fail response))))
(defn eval-in
  "Evaluate an opaque static Program in a named mission."
  [mission program-value]
  (let [response (tool/kernel-eval {:kind :embedded :program program-value :mission mission})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn eval-with-in
  "Evaluate an opaque static Program in a named mission with JSON parameters."
  [mission program-value params]
  (let [response (tool/kernel-eval {:kind :embedded
                                    :program program-value
                                    :params params
                                    :mission mission})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn check-source-in
  "Check bounded dynamic source against one named mission without executing it."
  [mission source]
  (let [response (tool/kernel-check-source {:source source :mission mission})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))
