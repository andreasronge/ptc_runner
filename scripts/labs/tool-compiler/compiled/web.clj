(ns lab.web
  "One generic extraction tool. The recipe is mission data, so compiling a new
  domain means writing a data block, never generating source."
  {:visibility :prompt})

(defn- value! [response]
  (if (= :ok (get response :status)) (get response :value) (fail response)))

(defn quotations
  "Return every record on one page, using the compiled recipe."
  {:signature "(url :string) -> {records [{text :string, author :string}]}" :effect :read}
  [url]
  (let [handle (get (value! (tool/web.open {"url" url})) "handle_id")
        snapshot (value! (tool/web.capture {"handle_id" handle}))
        extracted (value! (tool/web.extract
                            {"snapshot_id" (get snapshot "snapshot_id")
                             "container" (get data/recipe "container")
                             "fields" [{"name" "text" "selector" (get data/recipe "text_selector")}
                                       {"name" "author" "selector" (get data/recipe "author_selector")}]
                             "limit" 20}))]
    (value! (tool/web.close {"handle_id" handle}))
    {"records" (get extracted "records")}))
