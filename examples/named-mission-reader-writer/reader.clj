(ns example.reader "Read-only source API." {:visibility :prompt})

(defn read-source-page
  "Read one bounded source page. Pass nil first, then next_cursor."
  {:signature "(path :string, cursor :string?) -> {items [{byte_offset :int, text :string}], next_cursor :string?, content_hash :string}"}
  [path cursor]
  (let [arguments (if cursor {"path" path "cursor" cursor} {"path" path})
        response (tool/workspace.read arguments)]
    (if (= :ok (get response :status))
      (get response :value)
      (fail response))))
