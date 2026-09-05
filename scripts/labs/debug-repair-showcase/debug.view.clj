(ns debug.view
  "Readable source evidence pages over debug.nav. Source bytes, hashes, typed relationships, and page completeness are retained; redundant item bookkeeping is omitted."
  {:visibility :prompt})

(defn- source-page [collection page]
  (if (or (= collection "generated_sources") (= collection "prelude_sources"))
    (assoc page "items"
      (mapv #(select-keys % ["run_id" "evaluation_id" "parent_evaluation_id"
                             "component_id" "environment" "mission_name"
                             "source" "source_hash" "relationships"
                             "prelude_calls" "prelude_calls_available?"])
            (get page "items")))
    page))

(defn read
  "Read a focused evidence page. Pass the same collection, filters, limit, and cursor accepted by debug.nav/read. Source text and relationships are exact; non-source collections are unchanged. Use debug.nav/read if omitted bookkeeping is needed."
  {:signature "(run-id :string, options :map) -> :map"}
  [run-id options]
  (source-page (get options "collection") (debug.nav/read run-id options)))

(defn follow
  "Follow a complete typed relationship exactly as received and return a focused source page. Options accept only limit and cursor, as in debug.nav/follow. Page completeness and the original relationship are unchanged."
  {:signature "(run-id :string, relationship :map, options :map) -> :map"}
  [run-id relationship options]
  (let [result (debug.nav/follow run-id relationship options)]
    (assoc result "page"
      (source-page (get relationship "target_collection") (get result "page")))))
