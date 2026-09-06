(ns example.writer "Write-only destination API." {:visibility :prompt})

(defn write-result
  "Replace one UTF-8 destination file in the writer mission's private root."
  {:signature "(path :string, text :string) -> {path :string, bytes :int, content_hash :string}"}
  [path text]
  (let [response (tool/workspace.write {"path" path "content" text})]
    (if (= :ok (get response :status))
      (get response :value)
      (fail response))))
