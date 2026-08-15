(ns evidence.walk
  "Collect the evidence a diagnosis would have to rest on, and nothing more."
  {:visibility :prompt})

(defn- first-item [page] (first (get page "items")))

(defn- relation [item rel]
  (first (filter #(= (get % "rel") rel) (get item "relationships"))))

(defn- complete? [relationship]
  (and (map? relationship) (= (get relationship "state") "complete")))

(defn- hop [run-id relationship]
  (first-item (get (debug.nav/follow run-id relationship {}) "page")))

;; Walk the frozen dependency edges the failing call actually reached. The
;; walk is bounded, stops at the first edge the host did not prove complete,
;; and never widens to components outside that closure.
(defn- dependency-closure [run-id entry]
  (reduce
    (fn [chain _step]
      (let [dependency (relation (last chain) "dependency_prelude_source")]
        (if (complete? dependency)
          (conj chain (hop run-id dependency))
          chain)))
    [entry]
    (range 8)))

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
        chain (dependency-closure run-id entry)]
    {"run_id" run-id
     "terminal_reason" (get run "terminal_reason")
     "boundary_kind" (get error "kind")
     "nested_evaluations" (count (get children "items"))
     "generated_source" (get generated "source")
     "dependency_closure" (map #(get % "component_id") chain)
     "reached_sources" (map #(get % "source") chain)
     ;; Report how well the host proved every edge on the path, so a caller can
     ;; tell a supported diagnosis from an incomplete or ambiguous picture
     ;; instead of assuming the walk saw everything.
     "evidence_states" (states (concat [error generated] chain))
     ;; Nothing here selects a suspect. That judgement belongs to the caller.
     "diagnosis" nil}))
