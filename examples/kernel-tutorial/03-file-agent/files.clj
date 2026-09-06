(ns tutorial.files "Mission-only access to the granted file root." {:visibility :prompt})

(defn read-page
  "Read one bounded page of a UTF-8 file. Pass nil first, then next_cursor."
  {:signature "(path :string, cursor :string?) -> {items [{byte_offset :int, text :string}], next_cursor :string?, content_hash :string}"}
  [path cursor]
  (let [arguments (if cursor {"path" path "cursor" cursor} {"path" path})
        response (tool/workspace.read arguments)]
    (if (= :ok (get response :status))
      (get response :value)
      (fail response))))
