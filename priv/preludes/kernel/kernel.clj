(ns kernel "Explicit subordinate evaluation helpers." {:visibility :prompt})

(defn eval
  "Evaluate an opaque static Program in the mission environment."
  [mission program-value]
  (let [response (tool/kernel-eval {:kind :embedded :program program-value :mission mission})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn eval-source
  "Evaluate bounded dynamic source text in the mission environment."
  [mission source]
  (let [response (tool/kernel-eval {:kind :source :source source :mission mission})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn eval-with
  "Evaluate an opaque static Program with JSON parameters at data/params."
  [mission program-value params]
  (let [response (tool/kernel-eval {:kind :embedded
                                    :program program-value
                                    :params params
                                    :mission mission})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn eval-source-with
  "Evaluate bounded dynamic source with JSON parameters at data/params."
  [mission source params]
  (let [response (tool/kernel-eval {:kind :source
                                    :source source
                                    :params params
                                    :mission mission})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn check-source
  "Check bounded dynamic source against the live mission environment without executing it."
  [mission source]
  (let [response (tool/kernel-check-source {:source source :mission mission})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn check-terminal-source
  "Check that bounded dynamic source compiles and consists of exactly one top-level return or fail form, without executing it."
  [mission source]
  (let [response (tool/kernel-check-source {:source source
                                            :require :terminal
                                            :mission mission})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn mission-inventory
  "Return the frozen prompt-facing mission inventory JSON, including data grants."
  [mission]
  (let [response (tool/kernel-mission-inventory {:mission mission})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn mission-model-context
  "Return the compact deterministic mission context for the model prompt."
  [mission]
  (let [response (tool/kernel-mission-model-context {:mission mission})]
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

(defn result-contract-presentation
  "Return the bounded renderer-neutral application result contract, or nil."
  []
  (let [response (tool/kernel-result-contract {"presentation" true})]
    (if (= :ok (get response :status))
      (let [value (get response :value)]
        (if (string? value) (json/parse-string value) nil))
      (fail response))))

(defn phase-return-contract-presentation
  "Resolve one named phase-return contract and return its model projection."
  [name]
  (let [response (tool/kernel-result-contract {"phase_contract" name "presentation" true})]
    (if (= :ok (get response :status))
      (json/parse-string (get response :value))
      response)))

(defn validate-phase-return
  "Validate a non-final phase's explicit return against its named contract."
  [name value]
  (let [response (tool/kernel-result-contract {"phase_contract" name "value" value})]
    (if (= :ok (get response :status))
      (get response :value)
      (fail response))))
