(ns demo.files "Mission-only access to the granted file root." {:visibility :prompt})

(defn read-page [path cursor]
  (let [arguments (if cursor {"path" path "cursor" cursor} {"path" path})
        response (tool/workspace.read arguments)]
    (if (= :ok (get response :status))
      (get response :value)
      response)))

(defn- small-text [path]
  (let [page (read-page path nil)]
    (if (nil? (get page "next_cursor"))
      (str/join "" (map #(get % "text") (get page "items")))
      (fail {:status :error :kind :file-too-large :reason :more-pages}))))

(defn- record-value [name]
  (let [match (re-find #"value (\d+)" (small-text name))]
    (parse-long (second match))))

(defn sum-values []
  (let [names (filter (fn [line] (not (= line ""))) (split-lines (small-text "index.txt")))]
    (reduce + (map record-value names))))

(defn spin-forever []
  (loop [i 0] (recur (inc i))))

(defn exhaust-memory []
  (loop [s "memory-demo"] (recur (str s s))))
