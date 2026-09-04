(ns debug.terminal
  "Terminal diagnosis actions over a frozen capture. Call exactly one as the top-level program. A verified action completes the run itself; a refused one returns a map with \"refused\" true and a reason, so correct the report and call again."
  {:visibility :prompt})

(defn- nonblank-string? [value]
  (and (string? value) (not (blank? value))))

(defn- string-array? [value]
  (and (sequential? value) (seq value) (every? nonblank-string? value)))

(defn- refuse [reason] {"refused" true "reason" reason})

(defn- frozen-sources [run-id filters]
  (get (debug.nav/read run-id (assoc filters "collection" "prelude_sources" "limit" 20)) "items"))

(defn diagnose
  "Complete with a diagnosed report. Requires run_id, component_id, source_hash (the sha256 of the frozen source item you read), excerpt (a verbatim fragment of that source showing the defect), cause, and evidence. Refused unless the capture holds that component with that hash and the excerpt occurs in its source."
  {:signature "(report :map) -> :map"}
  [report]
  (if (not (map? report))
    (refuse "diagnose requires one report map")
    (let [run-id (get report "run_id")
          cid (get report "component_id")
          hash (get report "source_hash")
          excerpt (get report "excerpt")]
      (if (not (and (nonblank-string? run-id) (nonblank-string? cid)
                    (nonblank-string? hash) (nonblank-string? excerpt)
                    (nonblank-string? (get report "cause"))
                    (string-array? (get report "evidence"))))
        (refuse "diagnose requires run_id, component_id, source_hash, excerpt, cause, and non-empty evidence")
        (let [items (frozen-sources run-id {"component_id" cid})
              match (first (filter #(= hash (get % "source_hash")) items))]
          (cond
            (empty? items)
            (refuse (str "the capture holds no frozen source for component " cid))

            (nil? match)
            (refuse (str "source_hash does not match any frozen source of " cid
                         "; cite the source_hash of the item you read"))

            (not (includes? (get match "source") excerpt))
            (refuse "excerpt does not occur verbatim in that component's frozen source")

            :else
            (return {"decision" "diagnosed"
                     "component_id" cid
                     "source_hash" hash
                     "excerpt" excerpt
                     "cause" (get report "cause")
                     "evidence" (vec (get report "evidence"))})))))))

(defn- refutation [run-id entry]
  (cond
    (not (map? entry))
    "each missing entry must be a map with component_id, environment, or description"

    (nonblank-string? (get entry "component_id"))
    (let [items (frozen-sources run-id {"component_id" (get entry "component_id")})]
      (if (seq items)
        (str "the frozen source of " (get entry "component_id")
             " is in the capture (environment " (get (first items) "environment")
             "); read it before abstaining")
        nil))

    (nonblank-string? (get entry "environment"))
    (let [items (frozen-sources run-id {"environment" (get entry "environment")})]
      (if (seq items)
        (str "the " (get entry "environment") " environment holds frozen sources for "
             (join ", " (map #(get % "component_id") items))
             "; read them before abstaining")
        nil))

    (nonblank-string? (get entry "description"))
    nil

    :else
    "each missing entry must be a map with component_id, environment, or description"))

(defn abstain
  "Complete with an insufficient-evidence report. Requires run_id, cause, evidence, and missing: a non-empty list of maps naming what would decide the question, each with component_id, environment (\"workflow\" or \"mission\"), or description. Refused when a named source is in the capture: read it first."
  {:signature "(report :map) -> :map"}
  [report]
  (if (not (map? report))
    (refuse "abstain requires one report map")
    (let [run-id (get report "run_id")
          missing (get report "missing")]
      (if (not (and (nonblank-string? run-id)
                    (nonblank-string? (get report "cause"))
                    (string-array? (get report "evidence"))
                    (sequential? missing) (seq missing)))
        (refuse "abstain requires run_id, cause, non-empty evidence, and non-empty missing")
        (let [reasons (remove nil? (map #(refutation run-id %) missing))]
          (if (seq reasons)
            (refuse (join " | " reasons))
            (return {"decision" "insufficient-evidence"
                     "cause" (get report "cause")
                     "evidence" (vec (get report "evidence"))})))))))
