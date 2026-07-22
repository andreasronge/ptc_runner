(ns tutorial.files "Mission-only access to the granted file root." {:visibility :prompt})

(defn read-text
  "Read one UTF-8 file beneath the configured mission root."
  {:signature "(path :string) -> :string"}
  [path]
  (let [response (tool/fs-read {"path" path})]
    (if (= :ok (get response :status))
      (get-in response [:value "content"])
      (fail response))))
