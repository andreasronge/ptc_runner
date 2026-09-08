(ns site.recipe "The stale parser component that a validated candidate can replace.")

(defn extract
  "Extract quotation and author records from one captured page."
  {:signature "(snapshot_id :string) -> :map" :effect :read}
  [snapshot-id]
  (let [response (tool/web.extract
                   {"snapshot_id" snapshot-id
                    "container" "div.quote"
                    "fields" [{"name" "text" "selector" "span.text"}
                              {"name" "author" "selector" "small.author"}]
                    "limit" 10})]
    (if (= :ok (get response :status)) (get response :value) (fail response))))
