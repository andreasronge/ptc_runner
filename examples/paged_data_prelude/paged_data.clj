(ns paged
  "Bounded analysis helpers over paginated upstream sources."
  {:visibility :prompt})

(def default-limit 1000)
(def default-max-pages 25)
(def default-max-entries 5000)

(defn- opt
  [m k fallback]
  (or (get m k) (get m (name k)) fallback))

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
  (max 1 (or (opt (page-spec source) :limit nil) default-limit)))

(defn- source-max-pages
  [source]
  (max 1 (or (opt (page-spec source) :max-pages nil) default-max-pages)))

(defn- source-max-entries
  [source]
  (max 1 (or (opt (page-spec source) :max-entries nil) default-max-entries)))

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
  (reduce (fn [acc k] (if acc (get acc k) nil)) m path))

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
        paged-args (if (= mode :token)
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
  (if (= (parse-mode source) :jsonl)
    (json/parse-lines rows)
    rows))

(defn- page-rows
  [source page pos]
  (let [rows (parse-rows source (or (get-path page (rows-at source)) []))]
    (if (= (page-mode source) :chunk-index)
      (let [start-line (get-path page (start-line-at source))
            target-line (+ 1 (* pos (source-limit source)))
            drop-count (max 0 (- target-line (or start-line target-line)))]
        (drop drop-count rows))
      rows)))

(defn- next-pos
  [source page pos row-count]
  (let [mode (page-mode source)]
    (cond
      (= mode :token) (get-path page (token-at source))
      (= mode :chunk-index) (+ pos 1)
      :else (+ pos row-count))))

(defn- done?
  [source page rows next]
  (let [mode (page-mode source)]
    (cond
      (= mode :token) (not next)
      (= mode :chunk-index) (>= next (or (get-path page (total-pages-at source)) next))
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
  "Fold rows from a paginated source without materializing the full input."
  [source init step]
  (let [source (validate-source! source)]
    (loop [pos (if (= (page-mode source) :token) nil 0)
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
    (loop [pos (if (= (page-mode source) :token) nil 0)
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
     "presence" presence
     "string_counts" string-counts
     "key_counts" key-counts
     "collision_count" (+ (get acc "collision_count") (if (= prior-key-count 1) 1 0))}))

(defn profile
  "Compute sample, field presence, string-type counts, and one exact composite-key collision count in one pass."
  [source opts]
  (let [opts-map (profile-opts opts)
        folded
          (fold-pages
            source
            {"sample" [] "presence" {} "string_counts" {} "key_counts" {} "collision_count" 0}
            (fn [acc row] (add-profile-row source opts-map acc row)))]
    {"sample" (get folded "sample")
     "presence" (get folded "presence")
     "string_counts" (get folded "string_counts")
     "collision_count" (get folded "collision_count")}))
