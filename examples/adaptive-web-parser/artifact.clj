(ns demo.artifact "Read and write parser programs in one confined artifact root.")

(defn read-source [path]
  (let [response (tool/candidate.read {"path" path})]
    (if (= :ok (get response :status))
      (let [page (get response :value)]
        (if (nil? (get page "next_cursor"))
          {"found" true
           "source" (apply str (map #(get % "text") (get page "items")))
           "content_hash" (get page "content_hash")}
          (fail "parser source exceeded the single-page demo limit")))
      {"found" false})))

(defn write-source [path source]
  (let [response (tool/candidate.write {"path" path "content" source})]
    (if (= :ok (get response :status))
      (get response :value)
      (fail response))))
