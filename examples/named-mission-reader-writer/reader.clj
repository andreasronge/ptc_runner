(ns example.reader "Read-only source API." {:visibility :prompt})

(defn read-source
  "Read one UTF-8 source file from the reader mission's private root."
  {:signature "(path :string) -> :string"}
  [path]
  (let [response (tool/workspace.read {"path" path})]
    (if (= :ok (get response :status))
      (str (str/join "\n" (map #(get % "text") (get-in response [:value "lines"]))) "\n")
      (fail response))))
