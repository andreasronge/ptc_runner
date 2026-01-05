;; Smoke test: Conditional forms
;; Demonstrates: if, when, cond, if-let, when-let, truthiness

;; === Part 1: Truthiness rules ===

(let [;; Only nil and false are falsy
      falsy-values [nil false]
      truthy-values [true 0 "" [] {} :keyword "string" 1 -1 0.0]]

  {:falsy-nil (if nil "truthy" "falsy")
   :falsy-false (if false "truthy" "falsy")
   :truthy-true (if true "truthy" "falsy")
   :truthy-zero (if 0 "truthy" "falsy")
   :truthy-empty-string (if "" "truthy" "falsy")
   :truthy-empty-vector (if [] "truthy" "falsy")
   :truthy-empty-map (if {} "truthy" "falsy")
   :truthy-keyword (if :x "truthy" "falsy")})

;; === Part 2: if - two branches required ===

(let [x 10
      y 5]

  {:greater (if (> x y) "x wins" "y wins")
   :equal (if (= x y) "same" "different")
   :nested (if (> x 0)
             (if (> y 0)
               "both positive"
               "only x positive")
             "x not positive")
   :with-expressions (if (even? x)
                       (* x 2)
                       (+ x 1))})

;; === Part 3: when - single branch, implicit do ===

(do
  (def log [])

  ;; when returns nil if false
  (def result1 (when false "never"))

  ;; when returns body if true
  (def result2 (when true "yes"))

  ;; when with multiple expressions
  (def result3 (when (> 5 3)
                 (def log (conj log "evaluated"))
                 "returned"))

  ;; when for side-effect only
  (when true
    (def log (conj log "side-effect")))

  {:result1 result1
   :result2 result2
   :result3 result3
   :log log})

;; === Part 4: cond - multi-way branching ===

(let [classify (fn [n]
                 (cond
                   (< n 0) :negative
                   (= n 0) :zero
                   (< n 10) :small
                   (< n 100) :medium
                   :else :large))

      grade (fn [score]
              (cond
                (>= score 90) "A"
                (>= score 80) "B"
                (>= score 70) "C"
                (>= score 60) "D"
                :else "F"))]

  {:classifications (map classify [-5 0 5 50 500])
   :grades (map grade [95 85 75 65 55])})

;; === Part 5: cond without :else ===

(let [maybe-match (fn [x]
                    (cond
                      (= x 1) :one
                      (= x 2) :two
                      (= x 3) :three))]  ; no :else, returns nil

  {:one (maybe-match 1)
   :two (maybe-match 2)
   :none (maybe-match 99)})

;; === Part 6: if-let - conditional binding ===

(let [users {:alice {:name "Alice" :role :admin}
             :bob {:name "Bob" :role :user}}

      get-role (fn [user-key]
                 (if-let [user (get users user-key)]
                   (:role user)
                   :not-found))

      ;; if-let with map lookup
      find-admin (fn [user-map]
                   (if-let [admin (first (filter (fn [[_ u]] (= (:role u) :admin)) user-map))]
                     (second admin)
                     nil))]

  {:alice-role (get-role :alice)
   :bob-role (get-role :bob)
   :unknown-role (get-role :charlie)
   :admin (find-admin users)})

;; === Part 7: when-let - conditional binding without else ===

(do
  (def processed [])

  (defn maybe-process [value]
    (when-let [v value]
      (def processed (conj processed v))
      (* v 2)))

  {:result-10 (maybe-process 10)
   :result-nil (maybe-process nil)
   :result-false (maybe-process false)  ; false is falsy!
   :result-0 (maybe-process 0)          ; 0 is truthy
   :processed processed})

;; === Part 8: Combining conditionals ===

(do
  (defn process-item [{:keys [type value status]}]
    (when (= status :active)
      (cond
        (= type :number) (if (pos? value) value 0)
        (= type :string) (if (not (= value "")) value "default")
        :else nil)))

  (def items [{:type :number :value 42 :status :active}
              {:type :number :value -5 :status :active}
              {:type :string :value "hello" :status :active}
              {:type :string :value "" :status :active}
              {:type :number :value 100 :status :inactive}
              {:type :unknown :value "?" :status :active}])

  {:results (map process-item items)
   :non-nil (filter some? (map process-item items))})

;; === Part 9: Short-circuit evaluation ===

(do
  (def eval-log [])

  (defn tracked [label value]
    (def eval-log (conj eval-log label))
    value)

  ;; and short-circuits on first falsy
  (def and-result (and (tracked :a true)
                       (tracked :b false)
                       (tracked :c true)))  ; :c not evaluated

  (def and-log eval-log)
  (def eval-log [])

  ;; or short-circuits on first truthy
  (def or-result (or (tracked :x false)
                     (tracked :y true)
                     (tracked :z false)))  ; :z not evaluated

  {:and-result and-result
   :and-log and-log
   :or-result or-result
   :or-log eval-log})

;; === Part 10: Complex real-world pattern ===

(do
  (defn validate-user [{:keys [name email age]}]
    (cond
      (nil? name) {:error "Name required"}
      (nil? email) {:error "Email required"}
      (nil? age) {:error "Age required"}
      (< age 18) {:error "Must be 18+"}
      :else {:valid true :user {:name name :email email :age age}}))

  (defn process-registration [data]
    (if-let [result (validate-user data)]
      (if (:valid result)
        {:status "success" :user (:user result)}
        {:status "error" :message (:error result)})
      {:status "error" :message "Unknown error"}))

  {:valid-user (process-registration {:name "John" :email "john@test.com" :age 25})
   :missing-name (process-registration {:email "x@y.com" :age 20})
   :too-young (process-registration {:name "Kid" :email "kid@test.com" :age 15})})
