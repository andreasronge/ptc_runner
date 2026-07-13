(ns tutorial.files "Mission-only access to the granted file root." {:visibility :prompt})

(defn read-text [path]
  (let [response (tool/fs-read {"path" path})]
    (if (= :ok (get response :status))
      (get-in response [:value "content"])
      response)))
