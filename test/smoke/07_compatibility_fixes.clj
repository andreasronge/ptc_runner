;; Smoke test: Clojure compatibility fixes
;; Demonstrates: :or defaults, empty?/count on strings, nested destructuring,
;;               empty vector destructuring, destructuring nil

;; === Functions using fixed features ===

(defn greet-with-default [{:keys [name] :or {name "Guest"}}]
  (str "Hello, " name "!"))

(defn extract-nested [{{:keys [city]} :address}]
  city)

(defn safe-first [[x]]
  x)

(defn count-chars [s]
  (count s))

;; === Final result demonstrating all fixes ===

(let [;; Fix 1: :or defaults now return proper values (not internal tuples)
      default-result (greet-with-default {})
      named-result (greet-with-default {:name "Alice"})

      ;; Fix 2: empty? and count work on strings
      empty-str-check (empty? "")
      non-empty-check (empty? "hello")
      str-count (count "hello")
      unicode-count (count "日本語")

      ;; Fix 3: Nested map destructuring
      nested-data {:address {:city "Paris" :zip "75001"}}
      city-result (extract-nested nested-data)

      ;; Fix 4: Empty vector destructuring binds nil for missing elements
      [a b c] [1 2]
      partial-result [a b c]

      ;; Fix 5: Destructuring nil
      {:keys [x y]} nil
      nil-map-result [x y]

      ;; Combined: nested destructuring with defaults
      {{:keys [level] :or {level 1}} :config} {:config {}}
      config-level level]

  {:or-default default-result
   :or-provided named-result
   :empty-string empty-str-check
   :non-empty-string non-empty-check
   :string-count str-count
   :unicode-count unicode-count
   :nested-city city-result
   :partial-vector partial-result
   :nil-destructure nil-map-result
   :nested-with-default config-level})
