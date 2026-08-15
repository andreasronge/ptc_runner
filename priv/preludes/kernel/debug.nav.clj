(ns debug.nav
  "Typed navigation over one immutable private run-evidence capture. The mission must select its correlated inspection snapshot provider under the conventional name debug.nav."
  {:visibility :prompt})

(defn runs
  "List captured runs. Example: (debug.nav/runs {\"status\" \"error\" \"limit\" 5})."
  {:signature "(options :map) -> :map"}
  [options]
  (cap/unwrap! (tool/debug.nav.runs options)))

(defn open
  "Open a run and discover available collections, filters, identifiers, and completeness fields. Example: (debug.nav/open \"run-id\")."
  {:signature "(run-id :string) -> :map"}
  [run-id]
  (cap/unwrap! (tool/debug.nav.open {"run_id" run-id})))

(defn read
  "Read one native evidence page. Put collection and advertised filters directly in options; do not nest them under filters. Example: (debug.nav/read \"run-id\" {\"collection\" \"turns\" \"evaluation_id\" \"mission-evaluation-9\"})."
  {:signature "(run-id :string, options :map) -> :map"}
  [run-id options]
  (cap/unwrap! (tool/debug.nav.read (assoc options "run_id" run-id))))

(defn follow
  "Follow one typed relationship returned by an evidence item. The relationship supplies the exact target collection and filters; options may contain only limit and cursor. Unavailable or filterless relationships are refused. Returns the original relationship beside the complete native page envelope. Example: (debug.nav/follow run-id relationship {\"limit\" 20})."
  {:signature "(run-id :string, relationship :map, options :map) -> :map"}
  [run-id relationship options]
  (if (not (empty? (dissoc options "limit" "cursor")))
    (fail "debug.nav/follow options may contain only limit and cursor")
    (let [state (get relationship "state")
          filters (get relationship "filters")
          collection (get relationship "target_collection")]
      (if (or (= state "unavailable")
              (not (map? filters))
              (not (string? collection)))
        (fail "cannot follow an unavailable or filterless relationship")
        {"relationship" relationship
         "page"
         (read
           run-id
           (assoc
             (merge filters (select-keys options ["limit" "cursor"]))
             "collection"
             collection))}))))
