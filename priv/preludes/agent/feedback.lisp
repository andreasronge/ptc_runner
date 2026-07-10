(ns agent.feedback
  "Kernel feedback policy."
  {:visibility :prompt})

(def feedback-max-chars
  "Maximum encoded retry-feedback characters before the policy emits a bounded fallback."
  4096)

(def feedback-truncation-hint
  "Guidance included whenever retry feedback omits untrusted result detail."
  "Feedback was truncated. Retry with a smaller intermediate result; persisted definitions remain available by name.")

(defn- bounded-scalar-max-chars
  []
  512)

(defn- eval-result-keys
  []
  ["status" "reason" "message" "details" "value" "prints" "memory_summary"])

(defn- detail-keys
  []
  ["limit_bytes" "candidate_bytes" "memory_bytes" "turn"])

(defn- bounded-integer-max
  []
  10000000000000000000000000000000000000000000000000000000000000000)

(defn- oversized-number?
  [value]
  (and (integer? value)
       (or (> value (bounded-integer-max))
           (< value (- (bounded-integer-max))))))

(defn- scalar-truncated?
  [value]
  (cond
    (string? value) (> (count value) (bounded-scalar-max-chars))
    (number? value) (oversized-number? value)
    (or (boolean? value) (nil? value)) false
    :else true))

(defn- bounded-scalar
  [value]
  (cond
    (string? value)
    (if (> (count value) (bounded-scalar-max-chars))
      (subs value 0 (bounded-scalar-max-chars))
      value)

    (oversized-number? value)
    "<omitted: oversized number>"

    (or (number? value) (boolean? value) (nil? value))
    value

    :else
    "<omitted: non-scalar>"))

(defn- bounded-details
  [details]
  (if (map? details)
    (zipmap (detail-keys)
            (mapv (fn [key] (bounded-scalar (details key))) (detail-keys)))
    nil))

(defn- bounded-prints
  [prints]
  (if (sequential? prints)
    (mapv bounded-scalar (take 4 prints))
    []))

(defn- projection-truncated?
  [result]
  (let [details (result "details")
        prints (result "prints")
        scalar-fields (mapv (fn [key] (result key)) ["status" "reason" "message" "value"])]
    (or
      (not= (count result) (count (select-keys result (eval-result-keys))))
      (some scalar-truncated? scalar-fields)
      (and details
           (or
             (not (map? details))
             (not= (count details) (count (select-keys details (detail-keys))))
             (some scalar-truncated? (mapv (fn [key] (details key)) (detail-keys)))))
      (and prints
           (or
             (not (sequential? prints))
             (> (count (take 5 prints)) 4)
             (some scalar-truncated? (take 4 prints)))))))

(defn- bounded-eval-result
  [result]
  ;; memory_summary is already bounded by the evaluator. Every other retained
  ;; field is projected to fixed-size scalars before JSON encoding.
  {"status" (bounded-scalar (result "status"))
   "reason" (bounded-scalar (result "reason"))
   "message" (bounded-scalar (result "message"))
   "details" (bounded-details (result "details"))
   "value" (bounded-scalar (result "value"))
   "prints" (bounded-prints (result "prints"))
   "memory_summary" (result "memory_summary")})

(defn- fallback-feedback
  [instruction]
  (json/generate-string
    {"type" "ptc_lisp_eval_feedback"
     "instruction" instruction
     "truncated" true
     "hint" feedback-truncation-hint}))

(defn protocol-error
  "Render feedback for a model action that did not match the native protocol."
  [action cfg]
  (str "Protocol error: " (action "reason")
       ". Call " (cfg "protocol_tool_name") " with exactly one valid program string."))

(defn eval-feedback
  "Render feedback for a program that did not return."
  [result cfg]
  (let [instruction (str "Previous PTC-Lisp program did not return successfully. Call "
                         (cfg "protocol_tool_name")
                         " again with a corrected program that ends in (return value).")
        truncated? (projection-truncated? result)
        base-payload {"type" "ptc_lisp_eval_feedback"
                      "instruction" instruction
                      "untrusted_eval_result" (bounded-eval-result result)}
        payload (if truncated?
                  (assoc base-payload
                    "truncated" true
                    "hint" feedback-truncation-hint)
                  base-payload)
        encoded (json/generate-string payload)]
    (if (and encoded (<= (count encoded) feedback-max-chars))
      encoded
      (fallback-feedback instruction))))
