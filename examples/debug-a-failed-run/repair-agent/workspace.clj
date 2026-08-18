(ns debug.workspace
  "Derive a frozen source working set from generated prelude calls and their dependency relationships."
  {:visibility :prompt})

(defn- relation-kind? [kind relation]
  (= kind (get relation "rel")))

(defn- relations [kind items]
  (filter
    #(relation-kind? kind %)
    (mapcat #(get % "relationships") items)))

(defn- relation-key [relation]
  (let [filters (get relation "filters")]
    [(get filters "environment")
     (get filters "mission_name")
     (get filters "component_id")]))

(defn- seen? [seen key]
  (some #(= key %) seen))

(defn- source-view [source]
  (select-keys source ["component_id" "environment" "mission_name"
                       "source_hash" "source"]))

(defn changed
  "Return the complete dependency closure of components referenced by generated sources. Source order is the content-hash order, not call or manifest order."
  {:signature "(run-id :string, generated-sources [:map]) -> :map"}
  [run-id generated-sources]
  (let [roots (vec (relations "referenced_prelude_source" generated-sources))]
    (loop [frontier roots
           seen []
           files []
           complete? true
           steps 0]
      (cond
        (> steps 32)
        {"complete?" false
         "files" (vec (sort-by #(get % "source_hash") (map source-view files)))}

        (empty? frontier)
        {"complete?" complete?
         "files" (vec (sort-by #(get % "source_hash") (map source-view files)))}

        :else
        (let [relation (first frontier)
              remaining (vec (rest frontier))
              key (relation-key relation)
              followable? (= "complete" (get relation "state"))]
          (cond
            (seen? seen key)
            (recur remaining seen files complete? (inc steps))

            (not followable?)
            (recur remaining (conj seen key) files false (inc steps))

            :else
            (let [followed (debug.nav/follow run-id relation {"limit" 10})
                  page (get followed "page")
                  items (get page "items")
                  dependencies (relations "dependency_prelude_source" items)
                  page-complete? (and (not (get page "truncated"))
                                      (nil? (get page "next_cursor")))]
              (recur
                (vec (concat remaining dependencies))
                (conj seen key)
                (vec (concat files items))
                (and complete? page-complete?)
                (inc steps)))))))))
