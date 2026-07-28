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

  A nil cursor denotes the first page and leaves the arguments unchanged.
  Traversal stays explicit in the caller; this helper never follows or
  interprets a cursor."
  [arguments cursor]
  (if cursor
    (assoc arguments "cursor" cursor)
    arguments))
