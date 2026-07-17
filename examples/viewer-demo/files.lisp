(ns demo.files "Mission-only access to the granted file root." {:visibility :prompt})

(defn read-text [path]
  (let [response (tool/fs-read {"path" path})]
    (if (= :ok (get response :status))
      (get-in response [:value "content"])
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
