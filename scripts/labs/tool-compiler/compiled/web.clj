(ns lab.web
  "One compiled tool. The recipe is pinned data, so a call costs four page
  round trips and no model turns."
  {:visibility :prompt})

(defn- value! [response]
  (if (= :ok (get response :status)) (get response :value) (fail response)))

(def recipe
  {"container" "article.entry"
   "fields" [{"name" "text" "selector" "p.words"}
             {"name" "author" "selector" "span.speaker"}]})

(defn quotations
  "Return every quotation on one page as {text, author} records."
  {:signature "(url :string) -> {records [{text :string, author :string}]}" :effect :read}
  [url]
  (let [handle (get (value! (tool/web.open {"url" url})) "handle_id")
        snapshot (value! (tool/web.capture {"handle_id" handle}))
        extracted (value! (tool/web.extract
                            {"snapshot_id" (get snapshot "snapshot_id")
                             "container" (get recipe "container")
                             "fields" (get recipe "fields")
                             "limit" 20}))]
    (value! (tool/web.close {"handle_id" handle}))
    {"records" (get extracted "records")}))
