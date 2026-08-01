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

(defn with-cursor
  "Adds an opaque pagination cursor to a capability argument map.

  A nil cursor denotes the first page and removes any existing cursor.
  Traversal stays explicit in the caller; this helper never follows or
  interprets a cursor."
  [arguments cursor]
  (let [arguments (dissoc arguments "cursor" :cursor)]
    (if (nil? cursor)
      arguments
      (assoc arguments "cursor" cursor))))

(defn- pagination-result [items pages complete? snapshot-hash]
  (let [result {"items" items "pages" pages "complete?" complete?}]
    (if (= snapshot-hash :absent)
      result
      (assoc result "snapshot_hash" snapshot-hash))))

(defn collect-pages
  "Collects `items` from cursor-paginated responses up to `max-pages`.

  `fetch` receives nil for the first page and each opaque `next_cursor`
  afterward. The result reports how many pages were read and whether the
  source was exhausted. Snapshot-bound pages preserve their `snapshot_hash`
  and traversal fails if that identity changes. A page bound that stops
  traversal returns the collected prefix with `complete?` false; it never
  presents the prefix as complete."
  [fetch max-pages]
  (if (and (integer? max-pages) (pos? max-pages))
    (loop [cursor nil
           pages 0
           items []
           snapshot-hash :unset]
      (if (>= pages max-pages)
        (pagination-result items pages false snapshot-hash)
        (let [page (fetch cursor)
              items (into items (get page "items"))
              next-cursor (get page "next_cursor")
              page-hash (get page "snapshot_hash" :absent)]
          (if (or (= snapshot-hash :unset) (= snapshot-hash page-hash))
            (let [snapshot-hash (if (= snapshot-hash :unset) page-hash snapshot-hash)]
              (if (nil? next-cursor)
                (pagination-result items (inc pages) true snapshot-hash)
                (recur next-cursor (inc pages) items snapshot-hash)))
            (fail {:status :error :kind :invalid-response :reason :snapshot-changed})))))
    (fail {:status :error :kind :invalid-request :reason :invalid-max-pages})))
