(ns demo.files "Mission-only access to the granted file root." {:visibility :prompt})

(defn read-text [path]
  (let [response (tool/workspace.read {"path" path})]
    (if (= :ok (get response :status))
      (str (str/join "\n" (map #(get % "text") (get-in response [:value "lines"]))) "\n")
      response)))

(defn- record-value [name]
  (let [match (re-find #"value (\d+)" (read-text name))]
    (parse-long (second match))))

(defn sum-values []
  (let [names (filter (fn [line] (not (= line ""))) (split-lines (read-text "index.txt")))]
    (reduce + (map record-value names))))

(defn spin-forever []
  (loop [i 0] (recur (inc i))))

(defn exhaust-memory []
  (loop [s "memory-demo"] (recur (str s s))))
