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

(defn- edge-component [relationship] (get (get relationship "filters") "component_id"))

;; Two components in one round can name the same dependency, so drop an edge
;; already recorded and an edge repeated inside this round. Deduplicating the
;; edges rather than the fetched items also saves the redundant capability
;; call.
(defn- new-edges [seen edges]
  (reduce
    (fn [kept edge]
      (let [id (edge-component edge)]
        (if (or (some #(= % id) seen) (some #(= (edge-component %) id) kept))
          kept
          (conj kept edge))))
    []
    edges))

;; Walk every frozen dependency edge the failing call reached, breadth first.
;; A frozen graph orders dependencies before dependants, so it cannot cycle,
;; but deduplicate by component anyway and keep explicit bounds. Any edge the
;; host did not prove complete, and any followed edge that returned no item,
;; makes the result partial rather than silently short.
(defn- expand [run-id state]
  (let [seen (get state "seen")
        edges (mapcat dependency-edges (get state "frontier"))
        followable (filter complete? edges)
        available (new-edges seen followable)
        ;; Apply the component bound to this round's edges, not merely before
        ;; it: one high-degree frontier could otherwise follow far more than
        ;; the bound before anything notices.
        wanted (take (max 0 (- 64 (count seen))) available)
        found (remove nil? (map #(hop run-id %) wanted))]
    {"chain" (concat (get state "chain") found)
     ;; Record every attempted component, so a failed hop is not retried.
     "seen" (concat seen (map edge-component wanted))
     "frontier" found
     "complete?" (and (get state "complete?")
                      (= (count edges) (count followable))
                      (= (count wanted) (count available))
                      (= (count found) (count wanted)))}))

;; A round that finds nothing new empties the frontier, so a frontier that
;; survives every round means the walk ran out of rounds with edges still
;; unchecked.
(defn- closure [run-id roots complete?]
  (let [walked (reduce
                 (fn [state _round]
                   (if (empty? (get state "frontier"))
                     state
                     (expand run-id state)))
                 {"chain" roots
                  "seen" (map #(get % "component_id") roots)
                  "frontier" roots
                  "complete?" complete?}
                 (range 16))]
    (assoc walked "complete?"
           (and (get walked "complete?") (empty? (get walked "frontier"))))))

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
        ;; A program may call several components. Seed the walk from every one
        ;; the host proved, and let an unproven or empty reference make the
        ;; whole closure partial rather than quietly narrowing it to the first.
        referenced (relations generated "referenced_prelude_source")
        proven (new-edges [] (filter complete? referenced))
        roots (remove nil? (map #(hop run-id %) proven))
        walk (closure
               run-id
               roots
               (and (= (count referenced) (count proven)) (= (count roots) (count proven))))
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
