(ns cap "Capability discovery and envelope composition helpers." {:visibility :discoverable})

(defn list [] (tool/cap-list {}))
(defn describe [name] (tool/cap-describe {:name name}))

(defn unwrap!
  "Returns a capability response's value, failing the program on any error.

  Capability calls answer {:status :ok :value ...} or an error envelope. A
  wrapper that returns the envelope on failure makes every caller re-check it,
  and a caller that forgets treats an error map as ordinary data. This fails
  instead, so an unhandled provider error stops the program rather than
  flowing onward as a plausible-looking result."
  [response]
  (if (= :ok (get response :status))
    (get response :value)
    (fail response)))

(defn- pagination-fail [kind reason]
  (fail {:status :error :kind kind :reason reason}))

(defn- valid-token? [value]
  (and (string? value) (not (blank? value))))

(defn- fold-result [value pages complete? next-cursor snapshot-hash]
  {"value" value
   "pages" pages
   "complete?" complete?
   "next_cursor" next-cursor
   "snapshot_hash" snapshot-hash})

(defn fold-pages
  "Reduces cursor-paginated items into bounded caller-owned state.

  `fetch` receives nil for the first page or the opaque cursor supplied in
  `opts`. `step` receives accumulator then item. Every page must contain
  `items`, `next_cursor`, and a stable non-empty `snapshot_hash`.

  `opts` requires a positive `max_pages`. Resuming with `cursor` also requires
  the expected `snapshot_hash`. A page-bound stop returns `complete?` false and
  preserves `next_cursor`, so another evaluation can continue without retaining
  prior pages. Keep the accumulator bounded; pagination does not make an
  unbounded collection safe. Repeated cursors within one invocation fail instead
  of looping; a resumed invocation does not retain source-sized cursor history."
  [fetch step initial opts]
  (let [max-pages (get opts "max_pages")
        start-cursor (get opts "cursor")
        expected-hash (get opts "snapshot_hash")]
    (cond
      (not (and (integer? max-pages) (pos? max-pages)))
        (pagination-fail :invalid-request :invalid-max-pages)
      (and (not (nil? start-cursor)) (not (valid-token? start-cursor)))
        (pagination-fail :invalid-request :invalid-cursor)
      (and (not (nil? start-cursor)) (not (valid-token? expected-hash)))
        (pagination-fail :invalid-request :missing-snapshot-hash)
      :else
        (loop [cursor start-cursor
               pages 0
               value initial
               snapshot-hash expected-hash
               seen (if (nil? start-cursor) {} {start-cursor true})]
          (let [page (fetch cursor)
                items (get page "items" :absent)
                next-cursor (get page "next_cursor" :absent)
                page-hash (get page "snapshot_hash" :absent)]
            (cond
              (not (sequential? items))
                (pagination-fail :invalid-response :invalid-items)
              (not (valid-token? page-hash))
                (pagination-fail :invalid-response :missing-snapshot-hash)
              (and (not (nil? snapshot-hash)) (not= snapshot-hash page-hash))
                (pagination-fail :invalid-response :snapshot-changed)
              (= next-cursor :absent)
                (pagination-fail :invalid-response :missing-next-cursor)
              (and (not (nil? next-cursor)) (not (valid-token? next-cursor)))
                (pagination-fail :invalid-response :invalid-cursor)
              (and (not (nil? next-cursor)) (contains? seen next-cursor))
                (pagination-fail :invalid-response :cursor-cycle)
              :else
                (let [value (reduce step value items)
                      pages (inc pages)]
                  (cond
                    (nil? next-cursor)
                      (fold-result value pages true nil page-hash)
                    (>= pages max-pages)
                      (fold-result value pages false next-cursor page-hash)
                    :else
                      (recur next-cursor pages value page-hash
                             (assoc seen next-cursor true))))))))))
