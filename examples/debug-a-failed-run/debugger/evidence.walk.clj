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

;; The single place that turns edges into items, so the 64-component bound and
;; the deduplication apply to the roots exactly as they apply to every later
;; round. Withholding an edge, or following one that returns no item, makes the
;; walk partial rather than silently short.
(defn- follow-edges [run-id seen edges]
  (let [available (new-edges seen edges)
        wanted (take (max 0 (- 64 (count seen))) available)
        found (remove nil? (map #(hop run-id %) wanted))]
    {"found" found
     ;; Record every attempted component, so a failed hop is not retried.
     "seen" (concat seen (map edge-component wanted))
     "complete?" (and (= (count wanted) (count available))
                      (= (count found) (count wanted)))}))

;; Walk every frozen dependency edge the failing call reached, breadth first.
;; A frozen graph orders dependencies before dependants, so it cannot cycle,
;; but deduplicate by component anyway. An edge the host did not prove complete
;; also makes the result partial.
(defn- expand [run-id state]
  (let [edges (mapcat dependency-edges (get state "frontier"))
        followable (filter complete? edges)
        round (follow-edges run-id (get state "seen") followable)]
    {"chain" (concat (get state "chain") (get round "found"))
     "seen" (get round "seen")
     "frontier" (get round "found")
     "complete?" (and (get state "complete?")
                      (= (count edges) (count followable))
                      (get round "complete?"))}))

;; A round that finds nothing new empties the frontier, so a frontier that
;; survives every round means the walk ran out of rounds with edges still
;; unchecked.
(defn- closure [run-id seeded]
  (let [roots (get seeded "found")
        walked (reduce
                 (fn [state _round]
                   (if (empty? (get state "frontier"))
                     state
                     (expand run-id state)))
                 {"chain" roots
                  "seen" (get seeded "seen")
                  "frontier" roots
                  "complete?" (get seeded "complete?")}
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
        ;; the host proved, through the same bounded follow every later round
        ;; uses, and let an unproven reference make the closure partial rather
        ;; than quietly narrowing it to the first.
        referenced (relations generated "referenced_prelude_source")
        followable (filter complete? referenced)
        seeded (follow-edges run-id [] followable)
        walk (closure
               run-id
               (assoc seeded "complete?"
                      (and (get seeded "complete?")
                           (= (count referenced) (count followable)))))
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
