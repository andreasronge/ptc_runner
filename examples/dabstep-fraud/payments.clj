(ns dabstep.payments
  "Read-only, streaming access to the pinned DABStep payments table."
  {:visibility :prompt})

(defn- headers []
  ["psp_reference" "merchant" "card_scheme" "year" "hour_of_day"
   "minute_of_hour" "day_of_year" "is_credit" "eur_amount" "ip_country"
   "issuing_country" "device_type" "ip_address" "email_address"
   "card_number" "shopper_interaction" "card_bin"
   "has_fraudulent_dispute" "is_refused_by_adyen" "aci"
   "acquirer_country"])

(defn- known-columns [] (set (headers)))
(defn- column-index [] (zipmap (headers) (range (count (headers)))))
(defn- header-line [] (join "," (headers)))
(defn- max-carry [] 65536)

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
    (nil? value) nil
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

(defn- validate-cursor! [cursor columns]
  (if (not (and (map? cursor)
                (= (sort (keys cursor)) ["carry" "columns" "upstream"])
                (string? (get cursor "upstream"))
                (string? (get cursor "carry"))
                (not (includes? (get cursor "carry") "\n"))
                (<= (count (get cursor "carry")) (max-carry))))
    (fail {:status :error
           :kind :invalid-cursor
           :reason :malformed-cursor})
    (if (= columns (get cursor "columns"))
      cursor
      (fail {:status :error
             :kind :invalid-cursor
             :reason :columns-changed}))))

(defn- unwrap-page [response]
  (if (= :ok (get response :status))
    (get response :value)
    (fail response)))

(defn- project [columns lines]
  (let [position (column-index)
        selectors (vec (map (fn [c] [(get position c) c]) columns))]
    (vec (map (fn [line]
                (let [fields (split line ",")]
                  (vec (map (fn [selector]
                              (typed-cell (nth selector 1) (get fields (nth selector 0))))
                            selectors))))
              lines))))

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
        first-page? (nil? cursor)
        state (if first-page? nil (validate-cursor! cursor columns))
        arguments (if first-page?
                    {"path" "payments.csv"}
                    {"path" "payments.csv" "cursor" (get state "upstream")})
        page (unwrap-page (tool/workspace.read arguments))
        next-upstream (get page "next_cursor")
        text (join "" (map #(get % "text") (get page "items")))
        combined (str (if first-page? "" (get state "carry")) text)
        complete-at-boundary? (or (nil? next-upstream) (ends-with? combined "\n"))
        lines (split-lines combined)
        complete-lines (if complete-at-boundary? lines (butlast lines))
        next-carry (if complete-at-boundary? "" (last lines))
        data-lines (if first-page?
                     (if (= (first complete-lines) (header-line))
                       (rest complete-lines)
                       (fail {:status :error
                              :kind :invalid-payments-data
                              :reason :header-mismatch}))
                     complete-lines)
        hash (get page "content_hash")]
    {"columns" columns
     "rows" (project columns data-lines)
     "next_cursor" (if (nil? next-upstream)
                     nil
                     {"columns" columns
                      "upstream" next-upstream
                      "carry" next-carry})
     "content_hashes" (if (nil? hash) [] [hash])
     "read_calls" 1}))
