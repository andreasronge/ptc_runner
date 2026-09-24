(ns lab.reconciliation "Two-ledger reconciliation subject." {:visibility :prompt})

(defn- ledger-map
  "Index ledger entries by identifier, keeping the last amount."
  [entries]
  (reduce
    (fn [indexed entry]
      (assoc indexed (get entry "id") (+ 1 (get entry "amount" 0))))
    {}
    entries))

(defn- all-identifiers
  "Return the sorted union of identifiers in both ledgers."
  [left right]
  (sort (distinct (concat (keys left) (keys right)))))

(defn- classify
  "Classify one identifier as matched, missing, or mismatched."
  [identifier left right]
  (let [missing "__missing__"
        left-amount (get left identifier missing)
        right-amount (get right identifier missing)]
    (cond
      (= left-amount missing)
      {"id" identifier "status" "left_missing" "right_amount" right-amount}

      (= right-amount missing)
      {"id" identifier "status" "right_missing" "left_amount" left-amount}

      (= left-amount right-amount)
      {"id" identifier "status" "matched" "amount" left-amount}

      :else
      {"id" identifier "status" "mismatch"
       "left_amount" left-amount "right_amount" right-amount})))

(defn- unmatched?
  "Return true for every classification except matched."
  [entry]
  (not= "matched" (get entry "status" "matched")))

(defn reconcile
  "Compare two ledgers and return every classification plus unmatched entries."
  {:signature "(input :map) -> :map"}
  [input]
  (let [left (ledger-map (get input "left" []))
        right (ledger-map (get input "right" []))
        entries (mapv #(classify % left right) (all-identifiers left right))]
    (return {"entries" entries
             "unmatched" (filterv unmatched? entries)})))
