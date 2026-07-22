(ns fs "Read-only access beneath an explicitly granted file root." {:visibility :prompt})

(defn read [path]
  (let [response (tool/fs-read {:path path})]
    (if (= :ok (get response :status))
      (get response :value)
      response)))
