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
  "Normalizes one page into {:items [...] :cursor ...}.

  :cursor carries the opaque token for the next page, or nil at the end.
  Traversal stays explicit in the caller: this shapes a single page so a loop
  reads plainly, and deliberately does not fetch pages itself."
  [page]
  (let [value (if (= :ok (get page :status)) (get page :value) page)
        items (get value :items)
        cursor (get value :next_cursor)]
    {:items (if (vector? items) items [])
     :cursor (if (string? cursor) cursor nil)}))
