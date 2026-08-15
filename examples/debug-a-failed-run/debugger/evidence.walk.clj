(ns evidence.walk
  "Collect the evidence a diagnosis would have to rest on, and nothing more."
  {:visibility :prompt})

(defn- first-item [page] (first (get page "items")))

(defn- relations [item rel]
  (filter #(= (get % "rel") rel) (get item "relationships")))

(defn- relation [item rel] (first (relations item rel)))

(defn- complete? [relationship]
  (and (map? relationship) (= (get relationship "state") "complete")))

(defn- hop [run-id relationship]
  (first-item (get (debug.nav/follow run-id relationship {}) "page")))

(defn- dependency-edges [item] (relations item "dependency_prelude_source"))

;; Walk every frozen dependency edge the failing call reached, breadth first.
;; A frozen graph orders dependencies before dependants, so it cannot cycle,
;; but deduplicate by component anyway and keep explicit bounds. The walk
;; reports whether it saw the whole closure: an edge the host did not prove
;; complete, or either bound, makes the result partial rather than silently
;; short.
(defn- expand [run-id state]
  (let [frontier (get state "frontier")
        edges (mapcat dependency-edges frontier)
        followable (filter complete? edges)
        seen (get state "seen")
        found (map #(hop run-id %) followable)
        fresh (remove #(some (fn [id] (= id (get % "component_id"))) seen) found)]
    {"chain" (concat (get state "chain") fresh)
     "seen" (concat seen (map #(get % "component_id") fresh))
     "frontier" fresh
     "complete?" (and (get state "complete?") (= (count edges) (count followable)))}))

(defn- closure [run-id entry]
  (reduce
    (fn [state _round]
      (cond
        (empty? (get state "frontier")) state
        (>= (count (get state "seen")) 64) (assoc state "complete?" false)
        :else (expand run-id state)))
    {"chain" [entry]
     "seen" [(get entry "component_id")]
     "frontier" [entry]
     "complete?" true}
    (range 16)))

(defn- states [items]
  (sort (distinct (mapcat #(map (fn [r] (get r "state")) (get % "relationships")) items))))

(defn collect
  "Return the failed run's boundary error, generated program, and reached source."
  {:signature "(options :map) -> :map"}
  [options]
  (let [run (first-item (debug.nav/runs {"status" "error" "limit" (get options "limit")}))
        run-id (get run "run_id")
        error (first-item (debug.nav/read run-id {"collection" "execution_errors"}))
        children (get (debug.nav/follow run-id (relation error "child_evaluations") {}) "page")
        generated (first-item
                    (debug.nav/read
                      run-id
                      {"collection" "generated_sources"
                       "parent_evaluation_id" (get error "evaluation_id")}))
        entry (hop run-id (relation generated "referenced_prelude_source"))
        walk (closure run-id entry)
        chain (get walk "chain")]
    {"run_id" run-id
     "terminal_reason" (get run "terminal_reason")
     "boundary_kind" (get error "kind")
     "nested_evaluations" (count (get children "items"))
     "generated_source" (get generated "source")
     "dependency_closure" (map #(get % "component_id") chain)
     "reached_sources" (map #(get % "source") chain)
     ;; False means the walk stopped early: an edge the host could not prove,
     ;; or a bound. A diagnosis must not treat a partial closure as the whole
     ;; one.
     "closure_complete" (get walk "complete?")
     ;; Report how well the host proved every edge on the path, so a caller can
     ;; tell a supported diagnosis from an incomplete or ambiguous picture
     ;; instead of assuming the walk saw everything.
     "evidence_states" (states (concat [error generated] chain))
     ;; Nothing here selects a suspect. That judgement belongs to the caller.
     "diagnosis" nil}))
