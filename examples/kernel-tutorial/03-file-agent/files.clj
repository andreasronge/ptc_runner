(ns tutorial.files "Mission-only access to the granted file root." {:visibility :prompt})

(defn read-text
  "Read one UTF-8 file beneath the configured mission root."
  {:signature "(path :string) -> :string"}
  [path]
  (let [response (tool/workspace.read {"path" path})]
    (if (= :ok (get response :status))
      (str (str/join "\n" (map #(get % "text") (get-in response [:value "lines"]))) "\n")
      (fail response))))
