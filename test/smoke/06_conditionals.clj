;; Smoke test: Conditional forms
;; Demonstrates: if, when, cond, if-let, when-let, truthiness, short-circuit
;; Note: Only the LAST expression's result is compared

;; === defn definitions (used in final result) ===

(defn classify [n]
  (cond
    (< n 0) "negative"
    (= n 0) "zero"
    (< n 10) "small"
    (< n 100) "medium"
    :else "large"))

(defn grade [score]
  (cond
    (>= score 90) "A"
    (>= score 80) "B"
    (>= score 70) "C"
    (>= score 60) "D"
    :else "F"))

(defn maybe-match [x]
  (cond
    (= x 1) "one"
    (= x 2) "two"
    (= x 3) "three"))

(defn process-item [{:keys [type value status]}]
  (when (= status "active")
    (cond
      (= type "number") (if (pos? value) value 0)
      (= type "string") (if (not (= value "")) value "default")
      :else nil)))

(defn validate-reg [{:keys [name email age]}]
  (cond
    (nil? name) {:error "Name required"}
    (nil? email) {:error "Email required"}
    (nil? age) {:error "Age required"}
    (< age 18) {:error "Must be 18+"}
    :else {:valid true :user {:name name :email email :age age}}))

(defn process-registration [data]
  (if-let [result (validate-reg data)]
    (if (:valid result)
      {:status "success" :user (:user result)}
      {:status "error" :message (:error result)})
    {:status "error" :message "Unknown error"}))

;; === State for side-effect tests ===
(def when-log [])
(def processed [])
(def eval-log [])

(defn maybe-process [value]
  (when-let [v value]
    (def processed (conj processed v))
    (* v 2)))

(defn tracked [label value]
  (def eval-log (conj eval-log label))
  value)

;; === Execute side effects ===

;; when tests
(def when-result1 (when false "never"))
(def when-result2 (when true "yes"))
(def when-result3 (when (> 5 3)
                    (def when-log (conj when-log "evaluated"))
                    "returned"))
(when true (def when-log (conj when-log "side-effect")))

;; when-let tests
(def wl-10 (maybe-process 10))
(def wl-nil (maybe-process nil))
(def wl-false (maybe-process false))
(def wl-0 (maybe-process 0))

;; Short-circuit tests
(def and-result (and (tracked "a" true)
                     (tracked "b" false)
                     (tracked "c" true)))
(def and-log eval-log)
(def eval-log [])
(def or-result (or (tracked "x" false)
                   (tracked "y" true)
                   (tracked "z" false)))
(def or-log eval-log)

;; === Final result (this is what gets compared) ===

(let [x 10
      y 5
      users {"alice" {:name "Alice" :role "admin"}
             "bob" {:name "Bob" :role "user"}}
      get-role (fn [user-key]
                 (if-let [user (get users user-key)]
                   (:role user)
                   "not-found"))
      items [{"type" "number" "value" 42 "status" "active"}
             {"type" "number" "value" -5 "status" "active"}
             {"type" "string" "value" "hello" "status" "active"}
             {"type" "string" "value" "" "status" "active"}
             {"type" "number" "value" 100 "status" "inactive"}
             {"type" "unknown" "value" "?" "status" "active"}]]

  {:truthiness
   {:falsy-nil (if nil "truthy" "falsy")
    :falsy-false (if false "truthy" "falsy")
    :truthy-true (if true "truthy" "falsy")
    :truthy-zero (if 0 "truthy" "falsy")
    :truthy-empty-string (if "" "truthy" "falsy")
    :truthy-empty-vector (if [] "truthy" "falsy")
    :truthy-empty-map (if {} "truthy" "falsy")}

   :if-forms
   {:greater (if (> x y) "x wins" "y wins")
    :nested (if (> x 0)
              (if (> y 0) "both positive" "only x positive")
              "x not positive")
    :with-expr (if (even? x) (* x 2) (+ x 1))}

   :when-forms
   {:result1 when-result1
    :result2 when-result2
    :result3 when-result3
    :log when-log}

   :cond-forms
   {:classifications (map classify [-5 0 5 50 500])
    :grades (map grade [95 85 75 65 55])
    :no-else {:one (maybe-match 1) :two (maybe-match 2) :none (maybe-match 99)}}

   :if-let-forms
   {:alice-role (get-role "alice")
    :bob-role (get-role "bob")
    :unknown-role (get-role "charlie")}

   :when-let-forms
   {:result-10 wl-10
    :result-nil wl-nil
    :result-false wl-false
    :result-0 wl-0
    :processed processed}

   :short-circuit
   {:and-result and-result
    :and-log and-log
    :or-result or-result
    :or-log or-log}

   :registration
   {:valid-user (process-registration {:name "John" :email "john@test.com" :age 25})
    :missing-name (process-registration {:email "x@y.com" :age 20})
    :too-young (process-registration {:name "Kid" :email "kid@test.com" :age 15})}})
