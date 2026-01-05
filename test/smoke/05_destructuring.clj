;; Smoke test: Destructuring patterns
;; Demonstrates: vector, map, nested, :keys, :or, :as, in let/fn/defn

;; === Part 1: Vector destructuring in let ===

(let [;; Basic vector destructuring
      [a b] [1 2]

      ;; Skip with underscore
      [_ second _] [10 20 30]

      ;; Nested vectors
      [[x y] [z w]] [[1 2] [3 4]]

      ;; Mixed depth
      [first-item [nested-a nested-b]] [100 [200 300]]]

  {:basic [a b]
   :skipped second
   :nested-pairs [[x y] [z w]]
   :mixed [first-item nested-a nested-b]})

;; === Part 2: Map destructuring with :keys ===

(let [user {:name "Alice" :age 30 :email "alice@example.com"}

      ;; Basic :keys extraction
      {:keys [name age]} user

      ;; Partial extraction
      {:keys [email]} user

      ;; Multiple maps
      config {:debug true :timeout 5000}
      {:keys [debug timeout]} config]

  {:name name
   :age age
   :email email
   :debug debug
   :timeout timeout})

;; === Part 3: Map destructuring with :or defaults ===

(let [partial-user {:name "Bob"}

      ;; With defaults for missing keys
      {:keys [name age role] :or {age 0 role "guest"}} partial-user

      ;; All defaults
      {:keys [x y z] :or {x 1 y 2 z 3}} {}

      ;; Partial defaults
      config {:host "localhost"}
      {:keys [host port] :or {port 8080}} config]

  {:name name
   :age age
   :role role
   :defaults [x y z]
   :config {:host host :port port}})

;; === Part 4: Map destructuring with renaming ===

(let [api-response {:user_name "Carol" :user_id 123 :is_active true}

      ;; Rename keys to idiomatic names
      {user-name :user_name
       user-id :user_id
       active? :is_active} api-response]

  {:user-name user-name
   :user-id user-id
   :active? active?})

;; === Part 5: Map destructuring with :as ===

(let [data {:id 1 :name "Test" :meta {:created "2024-01-01"}}

      ;; Extract specific keys but keep whole map
      {:keys [id name] :as full-record} data

      ;; Can access non-destructured keys via :as binding
      meta-data (:meta full-record)]

  {:id id
   :name name
   :has-meta (some? meta-data)
   :full-keys (keys full-record)})

;; === Part 6: Nested destructuring (step by step) ===

(let [complex {:user {:profile {:name "Dave" :settings {:theme "dark"}}
                      :scores [85 92 78]}
               :metadata {:version 2}}

      ;; Step-by-step nested access (nested map destructuring not supported)
      {:keys [user metadata]} complex
      {:keys [profile scores]} user
      {:keys [version]} metadata
      {:keys [name settings]} profile
      {:keys [theme]} settings]

  {:name name
   :theme theme
   :scores scores
   :version version})

;; === Part 7: Destructuring in fn ===

(let [;; Vector destructuring in fn params
      swap (fn [[a b]] [b a])

      ;; Map destructuring in fn params
      greet (fn [{:keys [name title]}]
              (str title " " name))

      ;; With defaults in fn
      configure (fn [{:keys [host port] :or {host "localhost" port 80}}]
                  (str host ":" port))

      ;; Nested in fn
      extract-name (fn [{:keys [user]}]
                     (let [{:keys [name]} user]
                       name))]

  {:swapped (swap [1 2])
   :greeting (greet {:name "Smith" :title "Dr."})
   :default-config (configure {})
   :custom-config (configure {:port 8080})
   :extracted (extract-name {:user {:name "Eve"}})})

;; === Part 8: Destructuring in defn ===

(do
  ;; defn with vector destructuring
  (defn point-to-string [[x y]]
    (str "(" x ", " y ")"))

  ;; defn with map destructuring
  (defn user-display [{:keys [name email]}]
    (str name " <" email ">"))

  ;; defn with defaults
  (defn make-request [{:keys [method url body] :or {method "GET" body nil}}]
    {:method method :url url :body body})

  ;; defn with :as
  (defn validate-user [{:keys [name email] :as user}]
    (let [valid? (and name email)]
      (if valid?
        (assoc user :validated true)
        {:error "Missing required fields"})))

  ;; defn with vector destructuring, then map access
  (defn process-event [[event-type event-data]]
    (let [{:keys [timestamp data]} event-data]
      {:type event-type
       :time timestamp
       :payload data}))

  {:point (point-to-string [10 20])
   :user (user-display {:name "Frank" :email "frank@test.com"})
   :get-request (make-request {:url "/api/users"})
   :post-request (make-request {:method "POST" :url "/api/users" :body {:name "New"}})
   :valid-user (validate-user {:name "Grace" :email "grace@test.com"})
   :invalid-user (validate-user {:name "Incomplete"})
   :event (process-event [:click {:timestamp 1234567890 :data {:x 100 :y 200}}])})

;; === Part 9: Edge cases and additional patterns ===

(let [;; Partial extraction (some keys present, some missing)
      partial {:name "Test" :id 42}
      {:keys [name id missing]} partial

      ;; Using :as to keep original
      {:keys [x] :as original} {:x 1 :y 2 :z 3}

      ;; First of empty vector using fn
      first-or-nil (first [])

      ;; Combining vector and map access
      items [{:id 1} {:id 2} {:id 3}]
      [first-item second-item] items
      {:keys [id]} first-item]

  {:name name
   :id id
   :missing-is-nil missing
   :original-key-count (count (keys original))
   :x-value x
   :empty-first first-or-nil
   :first-item-id id})
