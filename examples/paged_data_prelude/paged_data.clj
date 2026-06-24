(ns paged
  "Bounded analysis helpers over paginated upstream sources.

  Workflow:
    1. (paged/offset-source server tool args opts) for offset + limit tools.
    2. (paged/inspect source {:sample 5}) to discover exact row field names.
    3. (paged/profile source opts) for one-pass row_count, field presence,
       string counts, and composite-key collisions.
    4. (paged/duplicate-records source {}) to find repeated content when a
       near-unique identifier hides duplicate rows.
    5. (paged/reconcile-totals source opts) when declared/control totals exist.
    6. If any reconciliation, built-in or hand-rolled, shows detail rows over a
       declared/control total, do not treat detail as authoritative until
       duplicate or inflated content under fresh identifiers is ruled out.
       Identifier uniqueness alone does not prove excess rows are real; run
       (paged/duplicate-records source {:ignore-fields [\"<id-field>\"]}) on
       the relevant overage group before assigning source-direction blame.

  Source maps use :server, :tool, :args, and nested :page keys. See
  (doc paged/profile) for the full source and opts shape."
  {:visibility :prompt})

(defn- default-limit [] 1000)
(defn- default-max-pages [] 25)
(defn- default-max-entries [] 5000)
(defn- default-id-ratio [] 0.99)
(defn- default-abs-tolerance [] 0.01)
(defn- default-rel-tolerance [] 1.0e-6)

(defn- opts-get
  [m k fallback]
  (or (get m k) (get m (name k)) fallback))

(defn offset-source
  "Build a source map for upstream tools paged by offset and limit arguments.

  Options: :limit, :offset-arg, :limit-arg, :rows-at, :parse, :max-pages,
  :max-entries. Defaults use offset/limit argument names and bounded scans."
  [server tool args opts]
  (let [opts-map (or opts {})]
    {:server server
     :tool tool
     :args (or args {})
     :page {:mode :offset
            :limit (opts-get opts-map :limit (default-limit))
            :offset-arg (opts-get opts-map :offset-arg "offset")
            :limit-arg (opts-get opts-map :limit-arg "limit")
            :rows-at (opts-get opts-map :rows-at [:value "rows"])
            :parse (opts-get opts-map :parse :value)
            :max-pages (opts-get opts-map :max-pages (default-max-pages))
            :max-entries (opts-get opts-map :max-entries (default-max-entries))}}))

(defn- opt
  [m k fallback]
  (or (get m k) (get m (name k)) fallback))

(defn- option-name
  [value]
  (if (keyword? value) (name value) value))

(defn- option=
  [actual expected]
  (= (option-name actual) (option-name expected)))

(defn- page-spec
  [source]
  (or (get source :page) (get source "page") {}))

(defn- has-page-spec?
  [source]
  (or (contains? source :page) (contains? source "page")))

(defn- misplaced-page-keys
  [source]
  (filter
    (fn [k] (or (contains? source k) (contains? source (name k))))
    [:page-mode :mode :limit :offset-arg :limit-arg :token-arg :rows-at :token-at
     :total-pages-at :start-line-at :parse :max-pages :max-entries]))

(defn- validate-source!
  [source]
  (let [keys (misplaced-page-keys source)]
    (if (and (not (has-page-spec? source)) (seq keys))
      (fail {:reason "paged_source_config_error"
             :message "Pagination options must be nested under :page."
             :misplaced_keys (map name keys)
             :example {:server (or (get source :server) (get source "server"))
                       :tool (or (get source :tool) (get source "tool"))
                       :args (or (get source :args) (get source "args"))
                       :page {:mode (or (source :page-mode) (source :mode))
                              :limit (source :limit)
                              :offset-arg (source :offset-arg)
                              :limit-arg (source :limit-arg)
                              :rows-at (source :rows-at)
                              :parse (source :parse)}}})
      source)))

(defn- source-args
  [source]
  (or (get source :args) (get source "args") {}))

(defn- source-server
  [source]
  (or (get source :server) (get source "server")))

(defn- source-tool
  [source]
  (or (get source :tool) (get source "tool")))

(defn- source-limit
  [source]
  (max 1 (or (opt (page-spec source) :limit nil) (default-limit))))

(defn- source-max-pages
  [source]
  (max 1 (or (opt (page-spec source) :max-pages nil) (default-max-pages))))

(defn- source-max-entries
  [source]
  (max 1 (or (opt (page-spec source) :max-entries nil) (default-max-entries))))

(defn- page-mode
  [source]
  (or (opt (page-spec source) :mode nil) :offset))

(defn- offset-arg
  [source]
  (or (opt (page-spec source) :offset-arg nil) :offset))

(defn- limit-arg
  [source]
  (or (opt (page-spec source) :limit-arg nil) :limit))

(defn- token-arg
  [source]
  (or (opt (page-spec source) :token-arg nil) :cursor))

(defn- rows-at
  [source]
  (or (opt (page-spec source) :rows-at nil) [:value "rows"]))

(defn- token-at
  [source]
  (or (opt (page-spec source) :token-at nil) [:value "next_cursor"]))

(defn- total-pages-at
  [source]
  (or (opt (page-spec source) :total-pages-at nil) [:value "totalChunks"]))

(defn- start-line-at
  [source]
  (or (opt (page-spec source) :start-line-at nil) [:value "startLine"]))

(defn- parse-mode
  [source]
  (opt (page-spec source) :parse :value))

(defn- get-path
  [m path]
  (get-in m path))

(defn- unwrap!
  [r]
  (if (r :ok)
    r
    (fail {:reason (r :reason) :message (r :message)})))

(defn- page-call
  [source pos]
  (let [mode (page-mode source)
        limit (source-limit source)
        args (source-args source)
        paged-args (if (option= mode :token)
                     (if pos
                       (assoc args (limit-arg source) limit (token-arg source) pos)
                       (assoc args (limit-arg source) limit))
                     (assoc args (limit-arg source) limit (offset-arg source) pos))]
    {:server (source-server source)
     :tool (source-tool source)
     :args paged-args}))

(defn- read-page!
  [source pos]
  (unwrap! (tool/call (page-call source pos))))

(defn- parse-rows
  [source rows]
  (if (option= (parse-mode source) :jsonl)
    (json/parse-lines rows)
    rows))

(defn- page-rows
  [source page pos]
  (let [rows (parse-rows source (or (get-path page (rows-at source)) []))]
    (if (option= (page-mode source) :chunk-index)
      (let [start-line (get-path page (start-line-at source))
            target-line (+ 1 (* pos (source-limit source)))
            drop-count (max 0 (- target-line (or start-line target-line)))]
        (drop drop-count rows))
      rows)))

(defn- next-pos
  [source page pos row-count]
  (let [mode (page-mode source)]
    (cond
      (option= mode :token) (get-path page (token-at source))
      (option= mode :chunk-index) (+ pos 1)
      :else (+ pos row-count))))

(defn- done?
  [source page rows next]
  (let [mode (page-mode source)]
    (cond
      (option= mode :token) (not next)
      (option= mode :chunk-index) (>= next (or (get-path page (total-pages-at source)) next))
      :else (< (count rows) (source-limit source)))))

(defn- too-many-entries!
  [source acc]
  (if (> (count acc) (source-max-entries source))
    (fail {:reason "max_entries_exceeded"
           :max_entries (source-max-entries source)})
    acc))

(defn- field-value
  [row field]
  (get row field))

(defn- key-for
  [row fields]
  (map (fn [field] (field-value row field)) fields))

(defn- key-for-loop
  [row fields]
  (loop [remaining fields
         acc []]
    (if (empty? remaining)
      acc
      (recur (rest remaining) (conj acc (field-value row (first remaining)))))))

(defn- inc-count
  [m k]
  (assoc m k (+ 1 (or (get m k) 0))))

(defn fold-pages
  "Fold a paginated source one row at a time without materializing the full input.

  The step callback is invoked as (step acc row) for each parsed record in page
  order. Despite the name, row is one record, not a page batch.

  Examples:
    (paged/fold-pages source 0 (fn [acc _row] (inc acc)))
    (paged/fold-pages source [] (fn [acc row] (if (pred row) (conj acc row) acc)))"
  [source init step]
  (let [source (validate-source! source)]
    (loop [pos (if (option= (page-mode source) :token) nil 0)
         pages 0
         acc init]
      (if (>= pages (source-max-pages source))
        (fail {:reason "max_pages_exceeded" :max_pages (source-max-pages source)})
        (let [page (read-page! source pos)
              rows (page-rows source page pos)
              acc2 (reduce step acc rows)
              next (next-pos source page pos (count rows))]
          (if (done? source page rows next)
            acc2
            (recur next (+ pages 1) acc2)))))))

(defn sample
  "Return at most n rows from a paginated source."
  [source n]
  (let [source (validate-source! source)
        limit (max 0 n)]
    (loop [pos (if (option= (page-mode source) :token) nil 0)
           pages 0
           acc []]
      (if (>= (count acc) limit)
        (take limit acc)
        (if (>= pages (source-max-pages source))
          (fail {:reason "max_pages_exceeded" :max_pages (source-max-pages source)})
          (let [page (read-page! source pos)
                rows (page-rows source page pos)
                acc2 (take limit (concat acc rows))
                next (next-pos source page pos (count rows))]
            (if (or (>= (count acc2) limit) (done? source page rows next))
              acc2
              (recur next (+ pages 1) acc2))))))))

(defn inspect
  "Inspect before profiling: return sample rows and describe summary so exact row field names can be chosen for :presence-fields, :string-fields, and :collision-fields."
  [source opts]
  (let [opts-map (or opts {})
        sample-size (max 0 (or (get opts-map :sample) (get opts-map "sample") 5))
        rows (sample source sample-size)]
    {"sample" rows
     "description" (describe rows)}))

(defn- present?
  [value]
  (and (not (nil? value)) (not= value "")))

(defn- update-field-presence
  [stats field value prior-rows]
  (let [current (or (get stats field) {"present" 0 "missing" prior-rows})
        present (present? value)]
    (assoc
      stats
      field
      {"present" (+ (get current "present") (if present 1 0))
       "missing" (+ (get current "missing") (if present 0 1))})))

(defn- add-row-presence
  [state row]
  (let [prior-rows (get state "rows")
        stats (get state "fields")
        stats-with-known
          (reduce
            (fn [acc field]
              (update-field-presence acc field (get row field) 0))
            stats
            (keys stats))
        stats-with-new
          (reduce
            (fn [acc field]
              (if (get stats field)
                acc
                (update-field-presence acc field (get row field) prior-rows)))
            stats-with-known
            (keys row))]
    {"rows" (+ prior-rows 1)
     "fields" stats-with-new}))

(defn field-presence
  "Count present and missing values for every field observed in the source."
  [source]
  (get
    (fold-pages
      source
      {"rows" 0 "fields" {}}
      (fn [acc row]
        (let [next (add-row-presence acc row)]
          (too-many-entries! source (get next "fields"))
          next)))
    "fields"))

(defn group-count
  "Count rows by one or more scalar fields."
  [source fields]
  (fold-pages
    source
    {}
    (fn [acc row]
      (let [k (json/generate-string (key-for row fields))]
        (too-many-entries! source (assoc acc k (+ 1 (or (get acc k) 0))))))))

(defn key-collisions
  "Return composite keys that occur more than once, with bounded counts."
  [source fields]
  (let [counts (group-count source fields)]
    (filter
      (fn [entry] (> (second entry) 1))
      counts)))

(defn- value-fingerprint
  [value]
  (json/generate-string value))

(defn- update-cardinality-field
  [source stat value]
  (let [current (or stat {"present" 0 "values" {} "capped" false})
        present-count (+ 1 (get current "present"))]
    (if (get current "capped")
      (assoc current "present" present-count)
      (let [values (assoc (get current "values") (value-fingerprint value) true)
            capped (> (count values) (source-max-entries source))]
        (if capped
          {"present" present-count "values" {} "capped" true}
          {"present" present-count "values" values "capped" false})))))

(defn- add-cardinality-row
  [source acc row]
  (let [fields
          (reduce
            (fn [stats field]
              (let [value (get row field)]
                (if (present? value)
                  (assoc stats field (update-cardinality-field source (get stats field) value))
                  stats)))
            (get acc "fields")
            (keys row))]
    {"row_count" (+ 1 (get acc "row_count"))
     "fields" fields}))

(defn- finalize-cardinality-field
  [row-count stat]
  (let [present-count (get stat "present")
        distinct-count (if (get stat "capped")
                         present-count
                         (count (get stat "values")))
        ratio (if (> present-count 0)
                (/ distinct-count present-count)
                0)]
    {"present" present-count
     "distinct" distinct-count
     "ratio" ratio
     "capped" (get stat "capped")}))

(defn field-cardinality
  "Report present, distinct, and distinct/present ratio for observed fields."
  [source]
  (let [folded
          (fold-pages
            source
            {"row_count" 0 "fields" {}}
            (fn [acc row] (add-cardinality-row source acc row)))
        row-count (get folded "row_count")
        fields (get folded "fields")]
    {"row_count" row-count
     "fields"
       (reduce
         (fn [acc field]
           (assoc acc field (finalize-cardinality-field row-count (get fields field))))
         {}
         (keys fields))}))

(defn- opts-list
  [opts k]
  (or (get opts k) (get opts (name k)) []))

(defn- opts-number
  [opts k fallback]
  (or (get opts k) (get opts (name k)) fallback))

(defn- list-set
  [values]
  (reduce (fn [acc value] (assoc acc value true)) {} values))

(defn- in-set?
  [m value]
  (= true (get m value)))

(defn- natural-key-fields
  [cardinality opts]
  (let [pinned (or (get opts :key-fields) (get opts "key-fields") (get opts "key_fields"))
        ignore (list-set (opts-list opts :ignore-fields))
        threshold (opts-number opts :id-ratio (default-id-ratio))
        fields (get cardinality "fields")]
    (if pinned
      pinned
      (vec
        (filter
          (fn [field]
            (let [stats (get fields field)]
              (and (not (in-set? ignore field))
                   (< (get stats "ratio") threshold))))
          (keys fields))))))

(defn- duplicate-summary
  [counts limit]
  (let [dups (filter (fn [entry] (> (second entry) 1)) counts)
        excess (reduce (fn [acc entry] (+ acc (- (second entry) 1))) 0 dups)]
    {"groups" (count dups)
     "excess_rows" excess
     "examples" (take limit dups)}))

(defn duplicate-records
  "Find repeated record content while excluding near-unique identifier fields.

  Options: :key-fields, :ignore-fields, :id-ratio, :limit. Returns key_fields,
  excluded fields, duplicate group count, excess_rows, and example groups."
  [source opts]
  (let [opts-map (or opts {})
        limit (opts-number opts-map :limit 10)
        pinned (or (get opts-map :key-fields) (get opts-map "key-fields") (get opts-map "key_fields"))
        cardinality (if pinned nil (field-cardinality source))
        key-fields (if pinned pinned (natural-key-fields cardinality opts-map))
        key-set (list-set key-fields)
        excluded (if pinned
                   []
                   (vec
                     (filter
                       (fn [field] (not (in-set? key-set field)))
                       (keys (get cardinality "fields")))))
        counts (group-count source key-fields)
        summary (duplicate-summary counts limit)]
    {"key_fields" key-fields
     "excluded" excluded
     "groups" (get summary "groups")
     "excess_rows" (get summary "excess_rows")
     "examples" (get summary "examples")}))

(defn- numeric-string?
  [value]
  (and (string? value) (re-matches #"-?\d+(\.\d+)?" value)))

(defn- coerce-number
  [value]
  (cond
    (number? value) value
    (numeric-string? value) (Double/parseDouble value)
    :else nil))

(defn- abs-number
  [value]
  (if (< value 0) (- 0 value) value))

(defn- within-tolerance?
  [delta declared abs-tol rel-tol]
  (<= (abs-number delta)
      (max abs-tol (* rel-tol (abs-number declared)))))

(defn- recon-status
  [actual declared abs-tol rel-tol]
  (let [delta (- actual declared)]
    (cond
      (within-tolerance? delta declared abs-tol rel-tol) "match"
      (> delta 0) "over"
      :else "under")))

(defn- measure-value
  [spec row]
  (cond
    (= spec :count) 1
    (= spec "count") 1
    (and (vector? spec) (= (first spec) :sum)) (or (coerce-number (get row (second spec))) 0)
    (and (vector? spec) (= (first spec) "sum")) (or (coerce-number (get row (second spec))) 0)
    :else 0))

(defn- sum-measure?
  [spec]
  (and (vector? spec)
       (or (= (first spec) :sum) (= (first spec) "sum"))))

(defn- measure-coercion
  [measure-name spec row]
  (if (sum-measure? spec)
    (let [field (second spec)
          raw (get row field)]
      (if (numeric-string? raw)
        {measure-name {"field" field "coerced_rows" 1}}
        {}))
    {}))

(defn- merge-measure-coercion
  [acc entry]
  (let [measure-name (first entry)
        info (second entry)
        current (or (get acc measure-name) {"field" (get info "field") "coerced_rows" 0})]
    (assoc acc measure-name
           {"field" (get current "field")
            "coerced_rows" (+ (get current "coerced_rows") (get info "coerced_rows"))})))

(defn- merge-coercions
  [acc coercions]
  (reduce merge-measure-coercion acc coercions))

(defn- apply-measures
  [acc measures row]
  (reduce
    (fn [next entry]
      (let [measure-name (first entry)
            spec (second entry)
            measured (assoc next measure-name (+ (or (get next measure-name) 0) (measure-value spec row)))
            row-coercions (measure-coercion measure-name spec row)]
        (if (seq row-coercions)
          (assoc measured "__coercions" (merge-coercions (or (get measured "__coercions") {}) row-coercions))
          measured)))
    acc
    measures))

(defn- group-direction
  [group-measures]
  (let [statuses (map (fn [entry] (get (second entry) "status")) group-measures)]
    (cond
      (some (fn [status] (= status "over")) statuses) "over"
      (some (fn [status] (= status "under")) statuses) "under"
      :else "match")))

(defn- overage-cue
  [over-keys id-field]
  (if (seq over-keys)
    (str
      "Overage in " (count over-keys) " group(s): actuals exceed the declared "
      "control total. An over-count in a detailed source is as consistent with "
      "duplicate or inflated records carrying fresh ids as with a stale control "
      "summary; identifier uniqueness alone does not resolve the direction. "
      "Before treating the detailed source as the more complete one, run "
      "(paged/duplicate-records source {:ignore-fields [\"" id-field "\"]}) "
      "scoped to the over groups to rule out repeated content.")
    nil))

(defn- coercion-cue
  [field count]
  (str
    "Measure field " field " included " count
    " string-typed value(s) that were coerced to numbers; this reconciliation "
    "assumes a lenient consumer. A strict or non-coercing consumer may reject "
    "or mishandle these rows, so do not report the type inconsistency as "
    "harmless to totals without checking the actual consumer."))

(defn- reconcile-opts-map
  [opts]
  (or opts {}))

(defn- reconcile-group-by
  [opts]
  (or (get opts :group-by) (get opts "group-by") (get opts "group_by")))

(defn- reconcile-measures
  [opts]
  (or (get opts :measures) (get opts "measures") {"count" :count}))

(defn- reconcile-declared
  [opts]
  (or (get opts :declared) (get opts "declared") {}))

(defn- reconcile-id-field
  [opts]
  (or (get opts :id-field) (get opts "id-field") (get opts "id_field") "record_id"))

(defn- reconcile-abs-tolerance
  [opts]
  (or (get opts :tolerance) (get opts "tolerance") (default-abs-tolerance)))

(defn- reconcile-rel-tolerance
  [opts]
  (or (get opts :rel-tolerance) (get opts "rel-tolerance") (get opts "rel_tolerance") (default-rel-tolerance)))

(defn- reconcile-actuals
  [source group-by measures]
  (fold-pages
    source
    {}
    (fn [acc row]
      (let [group-key (group-by row)]
        (assoc acc group-key (apply-measures (or (get acc group-key) {}) measures row))))))

(defn- add-group-coercion
  [acc group-key entry]
  (let [measure-name (first entry)
        info (second entry)
        current (or (get acc measure-name) {"field" (get info "field") "coerced_rows" 0 "groups" []})
        next-count (+ (get current "coerced_rows") (get info "coerced_rows"))]
    (assoc acc measure-name
           {"field" (get current "field")
            "coerced_rows" next-count
            "groups" (conj (get current "groups") group-key)})))

(defn- collect-coerced-measures
  [actuals]
  (reduce
    (fn [acc group-key]
      (reduce
        (fn [next entry] (add-group-coercion next group-key entry))
        acc
        (get-in actuals [group-key "__coercions"])))
    {}
    (keys actuals)))

(defn- add-coercion-cues
  [coerced]
  (reduce
    (fn [acc entry]
      (let [measure-name (first entry)
            info (second entry)]
        (assoc acc measure-name
               (assoc info "cue" (coercion-cue (get info "field") (get info "coerced_rows"))))))
    {}
    coerced))

(defn- reconcile-group
  [actuals declared measures abs-tol rel-tol group-key]
  (reduce
    (fn [acc entry]
      (let [measure-name (first entry)
            actual (or (get-in actuals [group-key measure-name]) 0)
            expected (or (get-in declared [group-key measure-name]) 0)
            delta (- actual expected)]
        (assoc acc measure-name {"actual" actual
                                 "declared" expected
                                 "delta" delta
                                 "status" (recon-status actual expected abs-tol rel-tol)})))
    {}
    measures))

(defn- add-direction-key
  [acc groups group-key]
  (let [direction (group-direction (get groups group-key))]
    (update acc direction (fnil conj []) group-key)))

(defn reconcile-totals
  "Reconcile actual grouped totals from SOURCE against declared/control totals.

  Opts:
    :group-by fn row -> group key
    :measures name -> :count or [:sum field]
    :declared group key -> {measure name -> declared value}
    :id-field near-unique identifier for the duplicate-records follow-up
    :tolerance absolute numeric slack, default 0.01
    :rel-tolerance relative numeric slack, default 1e-6

  Returns groups, disjoint summary buckets for over/under/match, and an
  overage_cue when actuals exceed declared totals. Direction is not settled by
  an overage: rule out duplicate or inflated detailed records before treating
  the detailed source as authoritative."
  [source opts]
  (let [opts-map (reconcile-opts-map opts)
        group-by (reconcile-group-by opts-map)
        measures (reconcile-measures opts-map)
        declared (reconcile-declared opts-map)
        id-field (reconcile-id-field opts-map)
        abs-tol (reconcile-abs-tolerance opts-map)
        rel-tol (reconcile-rel-tolerance opts-map)
        actuals (reconcile-actuals source group-by measures)
        coerced-measures (add-coercion-cues (collect-coerced-measures actuals))
        group-keys (distinct (concat (keys actuals) (keys declared)))
        groups
          (reduce
            (fn [acc group-key]
              (assoc acc group-key (reconcile-group actuals declared measures abs-tol rel-tol group-key)))
            {}
            group-keys)
        summary
          (reduce
            (fn [acc group-key] (add-direction-key acc groups group-key))
            {"over" [] "under" [] "match" []}
            group-keys)
        over-keys (get summary "over")]
    (cond->
      {"groups" groups
       "summary" summary}
      (seq (keys coerced-measures)) (assoc "coerced_measures" coerced-measures)
      (seq over-keys) (assoc "overage_cue" (overage-cue over-keys id-field)))))

(defn- profile-opts
  [opts]
  (or opts {}))

(defn- profile-sample-size
  [opts]
  (max 0 (or (get opts :sample) (get opts "sample") 0)))

(defn- profile-presence-fields
  [opts]
  (or (get opts :presence-fields) (get opts "presence_fields") (get opts "presence-fields") []))

(defn- profile-string-fields
  [opts]
  (or (get opts :string-fields) (get opts "string_fields") (get opts "string-fields") []))

(defn- profile-collision-fields
  [opts]
  (or (get opts :collision-fields) (get opts "collision_fields") (get opts "collision-fields") []))

(defn- add-profile-row
  [source opts acc row]
  (let [sample-size (profile-sample-size opts)
        sample (get acc "sample")
        presence
          (loop [fields (profile-presence-fields opts)
                 stats (get acc "presence")]
            (if (empty? fields)
              stats
              (let [field (first fields)]
                (recur (rest fields) (update-field-presence stats field (get row field) 0)))))
        string-counts
          (loop [fields (profile-string-fields opts)
                 counts (get acc "string_counts")]
            (if (empty? fields)
              counts
              (let [field (first fields)]
                (recur
                  (rest fields)
                  (if (string? (get row field))
                    (inc-count counts field)
                    counts)))))
        collision-fields (profile-collision-fields opts)
        prior-key-count (if (empty? collision-fields)
                          nil
                          (get (get acc "key_counts") (json/generate-string (key-for-loop row collision-fields))))
        key-counts
          (if (empty? collision-fields)
            (get acc "key_counts")
            (inc-count (get acc "key_counts") (json/generate-string (key-for-loop row collision-fields))))]
    (too-many-entries! source key-counts)
    {"sample" (if (< (count sample) sample-size) (conj sample row) sample)
     "row_count" (+ 1 (or (get acc "row_count") 0))
     "presence" presence
     "string_counts" string-counts
     "key_counts" key-counts
     "collision_count" (+ (get acc "collision_count") (if (= prior-key-count 1) 1 0))}))

(defn profile
  "Profile exact row field names in one pass.

  Use (paged/inspect source {:sample 5}) first when field names are unknown.

  Returns:
    {\"sample\" up to :sample rows
     \"row_count\" total rows processed
     \"presence\" field -> {\"present\" n \"missing\" n}
     \"string_counts\" field -> rows where that field value is a string
     \"collision_count\" composite keys with at least one duplicate row}

  collision_count only tests the caller-supplied :collision-fields. A zero
  count on a near-unique identifier does not rule out repeated record content;
  run (paged/duplicate-records source {}) for a record-level duplicate check.

  For offset + limit tools, prefer:
    (paged/offset-source \"pages\" \"read_lines\" {:path \"/data/events.jsonl\"}
      {:rows-at [:value \"content\"] :parse :jsonl :limit 500})

  Full source shape, with keyword or string keys accepted:
    {:server \"pages\"
     :tool \"read_large_file_chunk\"
     :args {:filePath \"/data/events.jsonl\"}
     :page {:mode :chunk-index
            :limit 500
            :offset-arg :chunkIndex
            :limit-arg :linesPerChunk
            :rows-at [:value \"content\"]
            :parse :jsonl
            :total-pages-at [:value \"totalChunks\"]
            :start-line-at [:value \"startLine\"]
            :max-pages 20
            :max-entries 10000}}

  Opts shape:
    {:sample 3
     :presence-fields [\"status\"]
     :string-fields [\"amount\"]
     :collision-fields [\"entity_id\" \"event_time\"]}

  Use \"row_count\" as line_count when each parsed row is one input line."
  [source opts]
  (let [opts-map (profile-opts opts)
        folded
          (fold-pages
            source
            {"sample" [] "row_count" 0 "presence" {} "string_counts" {} "key_counts" {} "collision_count" 0}
            (fn [acc row] (add-profile-row source opts-map acc row)))]
    {"sample" (get folded "sample")
     "row_count" (get folded "row_count")
     "presence" (get folded "presence")
     "string_counts" (get folded "string_counts")
     "collision_count" (get folded "collision_count")}))
