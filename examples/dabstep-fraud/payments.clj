(ns dabstep.payments
  "Read-only, streaming access to a verified column projection of the pinned DABStep payments table."
  {:visibility :prompt})

(defn- headers []
  ["psp_reference" "merchant" "card_scheme" "year" "hour_of_day"
   "minute_of_hour" "day_of_year" "is_credit" "eur_amount" "ip_country"
   "issuing_country" "device_type" "ip_address" "email_address"
   "card_number" "shopper_interaction" "card_bin"
   "has_fraudulent_dispute" "is_refused_by_adyen" "aci"
   "acquirer_country"])

(defn- known-columns [] (set (headers)))
(defn- integer-columns []
  #{"year" "hour_of_day" "minute_of_hour" "day_of_year"})
(defn- float-columns [] #{"eur_amount"})
(defn- boolean-columns []
  #{"is_credit" "has_fraudulent_dispute" "is_refused_by_adyen"})

(defn- parse-number [parser column value]
  (let [parsed (parser value)]
    (if (nil? parsed)
      (fail {:status :error
             :kind :invalid-payments-data
             :reason :invalid-number
             :column column})
      parsed)))

(defn- parse-boolean [column value]
  (cond
    (= value "True") true
    (= value "False") false
    :else (fail {:status :error
                 :kind :invalid-payments-data
                 :reason :invalid-boolean
                 :column column})))

(defn- typed-cell [column value]
  (cond
    (= value "") nil
    (contains? (integer-columns) column) (parse-number parse-long column value)
    (contains? (float-columns) column) (parse-number parse-double column value)
    (contains? (boolean-columns) column) (parse-boolean column value)
    :else value))

(defn- validate-columns! [columns]
  (if (and (vector? columns)
           (not (empty? columns))
           (= (count columns) (count (distinct columns)))
           (every? #(and (string? %) (contains? (known-columns) %)) columns))
    columns
    (fail {:status :error
           :kind :invalid-columns
           :reason :expected-distinct-non-empty-known-column-vector})))

(defn- unwrap-page [response]
  (if (= :ok (get response :status))
    (get response :value)
    (fail response)))

(defn- read-column [column previous]
  (if (and (not (nil? previous))
           (or (get previous "done")
               (not (empty? (get previous "values")))))
    (assoc previous "content_hash" nil "read_calls" 0)
    (let [first-page? (nil? previous)
          upstream-cursor (if first-page?
                            nil
                            (get previous "upstream_cursor"))
          arguments (if first-page?
                      {"path" (str "columns/" column ".txt") "limit" 8}
                      {"path" (str "columns/" column ".txt")
                       "cursor" upstream-cursor
                       "limit" 8})
          page (unwrap-page (tool/workspace.read arguments))
          next-upstream-cursor (get page "next_cursor")
          carry (if first-page? "" (get previous "carry" ""))
          text (join "" (map #(get % "text") (get page "items")))
          combined (str carry text)
          complete-at-boundary? (or (nil? next-upstream-cursor)
                                    (ends-with? combined "\n"))
          lines (split-lines combined)
          complete-lines (if complete-at-boundary? lines (butlast lines))
          next-carry (if complete-at-boundary? "" (last lines))
          data-lines (if first-page?
                       (if (= column (first complete-lines))
                         (rest complete-lines)
                         (fail {:status :error
                                :kind :invalid-payments-data
                                :reason :header-mismatch
                                :column column}))
                       complete-lines)
          old-values (if first-page? [] (get previous "values"))
          new-values (vec (concat old-values
                                  (map #(typed-cell column %) data-lines)))]
      {"upstream_cursor" next-upstream-cursor
       "carry" next-carry
       "values" new-values
       "done" (nil? next-upstream-cursor)
       "content_hash" (get page "content_hash")
       "read_calls" 1})))

(defn- compact-state [state emitted]
  {"upstream_cursor" (get state "upstream_cursor")
   "carry" (get state "carry")
   "values" (vec (drop emitted (get state "values")))
   "done" (get state "done")})

(defn fraud-definition
  "Return the metric definition supplied by the official DABStep benchmark manual. Use it when interpreting fraud comparisons."
  {:signature "() -> :string"}
  []
  "Fraud is defined as the ratio of fraudulent volume over total volume.")

(defn read-page
  "Read aligned rows from a model-chosen projection of the pinned payments table. Pass nil first, then pass next_cursor unchanged and keep the same distinct columns. Available columns: psp_reference, merchant, card_scheme, year, hour_of_day, minute_of_hour, day_of_year, is_credit, eur_amount, ip_country, issuing_country, device_type, ip_address, email_address, card_number, shopper_interaction, card_bin, has_fraudulent_dispute, is_refused_by_adyen, aci, acquirer_country. Each row is a value vector in the requested column order. Numeric and Boolean fields are typed; empty cells are nil. Continue until next_cursor is nil."
  {:signature "(cursor :map?, columns [:string]) -> {columns [:string], rows [[:any]], next_cursor :map?, content_hashes [:string], read_calls :int}"}
  [cursor requested-columns]
  (let [columns (validate-columns! requested-columns)
        _ (if (and (not (nil? cursor))
                   (not (= columns (get cursor "columns"))))
            (fail {:status :error
                   :kind :invalid-cursor
                   :reason :columns-changed})
            nil)
        previous-states (if (nil? cursor) {} (get cursor "states"))
        states (zipmap columns
                       (map #(read-column % (get previous-states %)) columns))
        emitted (apply min
                       (map #(count (get (get states %) "values")) columns))
        rows (vec
               (map (fn [index]
                      (vec (map #(nth (get (get states %) "values") index)
                                columns)))
                    (range emitted)))
        next-states (zipmap columns
                            (map #(compact-state (get states %) emitted) columns))
        finished? (every? (fn [column]
                            (let [state (get next-states column)]
                              (and (get state "done")
                                   (empty? (get state "values")))))
                          columns)
        hashes (vec (filter #(not (nil? %))
                            (map #(get (get states %) "content_hash") columns)))
        read-calls (reduce + 0 (map #(get (get states %) "read_calls") columns))]
    {"columns" columns
     "rows" rows
     "next_cursor" (if finished?
                     nil
                     {"columns" columns "states" next-states})
     "content_hashes" hashes
     "read_calls" read-calls}))
