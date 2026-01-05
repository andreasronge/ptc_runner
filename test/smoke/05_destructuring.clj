;; Smoke test: Destructuring patterns
;; Demonstrates: vector, map, nested, :keys, :as, in let/fn/defn
;; Note: Only the LAST expression's result is compared
;; Note: :or defaults in defn have known issues, tested separately

;; === defn with destructuring (defined first, used in final result) ===

(defn point-to-string [[x y]]
  (str "(" x ", " y ")"))

(defn user-display [{:keys [name email]}]
  (str name " <" email ">"))

;; Simple defn without :or defaults
(defn make-request [{:keys [method url body]}]
  {:method (or method "GET") :url url :body body})

(defn validate-user [{:keys [name email] :as user}]
  (let [valid? (and name email)]
    (if valid?
      (assoc user :validated true)
      {:error "Missing required fields"})))

(defn process-event [[event-type event-data]]
  (let [{:keys [timestamp data]} event-data]
    {:type event-type
     :time timestamp
     :payload data}))

;; === Final result with all destructuring patterns ===

(let [;; Vector destructuring
      [a b] [1 2]
      [_ second-val _] [10 20 30]
      [[x y] [z w]] [[1 2] [3 4]]
      [first-item [nested-a nested-b]] [100 [200 300]]

      ;; Map destructuring with :keys
      user {:name "Alice" :age 30 :email "alice@example.com"}
      {:keys [name age email]} user

      ;; Map with renaming
      api-response {:user_name "Carol" :user_id 123 :is_active true}
      {renamed-name :user_name renamed-id :user_id active? :is_active} api-response

      ;; Map with :as
      data {:id 1 :data-name "Test" :meta {:created "2024-01-01"}}
      {:keys [id data-name] :as full-record} data

      ;; Nested access (step by step)
      complex {:user {:profile {:name "Dave" :settings {:theme "dark"}} :scores [85 92 78]}
               :metadata {:version 2}}
      {:keys [user-data metadata]} {:user-data (:user complex) :metadata (:metadata complex)}
      {:keys [profile scores]} user-data
      {:keys [version]} metadata
      {:keys [nested-name settings]} {:nested-name (:name profile) :settings (:settings profile)}
      {:keys [theme]} settings

      ;; fn with destructuring (no :or defaults to avoid issues)
      swap (fn [[a b]] [b a])
      greet (fn [{:keys [name title]}] (str title " " name))
      configure (fn [{:keys [host port]}]
                  (str (or host "localhost") ":" (or port 80)))

      ;; Edge cases
      partial-data {:edge-name "Test" :edge-id 42}
      {:keys [edge-name edge-id missing]} partial-data
      first-or-nil (first [])
      items [{:id 1} {:id 2} {:id 3}]
      [first-item-map] items
      {:keys [first-id]} {:first-id (:id first-item-map)}]

  {:vector-basic [a b]
   :vector-skip second-val
   :vector-nested [[x y] [z w]]
   :vector-mixed [first-item nested-a nested-b]
   :map-keys {:name name :age age :email email}
   :map-renamed {:name renamed-name :id renamed-id :active active?}
   :map-as {:id id :name data-name :key-count (count (keys full-record))}
   :nested {:name nested-name :theme theme :scores scores :version version}
   :fn-swap (swap [1 2])
   :fn-greet (greet {:name "Smith" :title "Dr."})
   :fn-configure-default (configure {})
   :fn-configure-custom (configure {:port 8080})
   :defn-point (point-to-string [10 20])
   :defn-user (user-display {:name "Frank" :email "frank@test.com"})
   :defn-request-get (make-request {:url "/api/users"})
   :defn-request-post (make-request {:method "POST" :url "/api/users" :body {:name "New"}})
   :defn-validate-valid (validate-user {:name "Grace" :email "grace@test.com"})
   :defn-validate-invalid (validate-user {:name "Incomplete"})
   :defn-event (process-event ["click" {:timestamp 1234567890 :data {:x 100 :y 200}}])
   :edge-missing missing
   :edge-first-nil first-or-nil
   :edge-first-id first-id})
