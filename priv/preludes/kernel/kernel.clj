(ns kernel "Explicit subordinate evaluation helpers." {:visibility :prompt})

(defn- json-contract-value? [value]
  ;; Quoted symbol references intentionally report :unknown (DIV-19), but the
  ;; host serializes them as their inert display strings. The host still
  ;; performs the exact canonical JSON projection after this shape check.
  (cond
    (or (nil? value)
        (true? value)
        (false? value)
        (string? value)
        (= :unknown (type value))
        (integer? value)
        (float? value))
    true

    (map? value)
    (every? (fn [[key nested]]
              (and (or (string? key) (= :unknown (type key)))
                   (json-contract-value? nested)))
            value)

    (sequential? value)
    (every? json-contract-value? value)

    :else false))

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
  "Evaluate bounded dynamic source text in the named mission space."
  [space source]
  (let [response (tool/kernel-eval {:kind :source :source source :space space})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn eval-source-with-in
  "Evaluate bounded dynamic source in the named mission space with JSON parameters."
  [space source params]
  (let [response (tool/kernel-eval {:kind :source
                                    :source source
                                    :params params
                                    :space space})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn mission-model-context-in
  "Return the compact deterministic mission context for one named space."
  [space]
  (let [response (tool/kernel-mission-model-context {:space space})]
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
  (let [response (tool/kernel-result-contract
                   {"value" value
                    "json_value" (json-contract-value? value)})]
    (if (= :ok (get response :status))
      (get response :value)
      (fail response))))
