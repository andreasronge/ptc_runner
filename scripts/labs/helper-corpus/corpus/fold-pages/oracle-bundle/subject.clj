(ns cap "Capability discovery and envelope composition helpers." {:visibility :discoverable})

(defn list
  "Lists capabilities installed in the current environment."
  []
  (tool/cap-list {}))

(defn describe
  "Returns the installed description for one capability name."
  [name]
  (tool/cap-describe {:name name}))

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
  `opts`. It must check capability envelopes (for example with cap/unwrap!)
  before returning a page. `step` receives accumulator then item; every item
  is reduced before following the page's `next_cursor`.

  `opts` requires a positive `max_pages`. `consistency` defaults to
  \"snapshot\": every page needs a stable non-empty `snapshot_hash`, and
  resuming with `cursor` requires the expected `snapshot_hash`.
  Set `consistency` to \"cursor\" only for providers whose opaque cursors
  enforce change detection. That mode neither requires nor checks snapshot
  hashes and returns nil `snapshot_hash`; page-local `content_hash` is never
  a snapshot identity. Provider errors must still fail through `fetch`.

  A page-bound stop returns `complete?` false and preserves `next_cursor`,
  so another evaluation can continue without retaining prior pages. Keep the
  accumulator bounded; pagination does not make an unbounded collection safe.
  Repeated cursors within one invocation fail instead of looping; a resumed
  invocation does not retain source-sized cursor history.
  See the MCP reference's bulk-read example for item, byte, time, and call
  budgeting alongside the helper's page bound."
  [fetch step initial opts]
  (let [max-pages (get opts "max_pages")
        start-cursor (get opts "cursor")
        consistency (get opts "consistency" "snapshot")
        cursor-owned? (= consistency "cursor")
        expected-hash (if cursor-owned? nil (get opts "snapshot_hash"))]
    (cond
      (not (contains? #{"snapshot" "cursor"} consistency))
        (pagination-fail :invalid-request :invalid-consistency)
      (not (and (integer? max-pages) (pos? max-pages)))
        (pagination-fail :invalid-request :invalid-max-pages)
      (and (not (nil? start-cursor)) (not (valid-token? start-cursor)))
        (pagination-fail :invalid-request :invalid-cursor)
      (and (not cursor-owned?) (not (nil? start-cursor))
           (not (valid-token? expected-hash)))
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
                page-hash (if cursor-owned? nil (get page "snapshot_hash" :absent))]
            (cond
              (not (sequential? items))
                (pagination-fail :invalid-response :invalid-items)
              (and (not cursor-owned?) (not (valid-token? page-hash)))
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

(defn corpus [input]
  (return
    (fold-pages
      (fn [cursor] (get (get input "pages") (if (nil? cursor) "first" cursor)))
      + 0 (get input "opts"))))
