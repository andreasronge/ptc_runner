(ns incident.evidence
  "Read-only access to one incident's evidence records."
  {:visibility :prompt})

(defn- unwrap [response]
  (if (= :ok (get response :status))
    (get response :value)
    (fail response)))

(defn- with-optional [arguments key value]
  (if (nil? value)
    arguments
    (assoc arguments key value)))

(defn list-sources
  "List which evidence sources exist for one incident, with record counts and
  the time bounds of each source."
  {:signature "(incident_id :string) -> :map"}
  [incident-id]
  (unwrap (tool/evidence.list_sources {"incident_id" incident-id})))

(defn search
  "Search one incident's evidence summaries. Pass nil for query, source, or
  limit to leave that filter unset. Summaries carry the content digest but not
  the record body; call `get-record` for the body."
  {:signature "(incident_id :string, query :string?, source :string?, limit :int?) -> :map"}
  [incident-id query source limit]
  (unwrap
    (tool/evidence.search
      (-> {"incident_id" incident-id}
          (with-optional "query" query)
          (with-optional "source" source)
          (with-optional "limit" limit)))))

(defn get-record
  "Fetch one evidence record, including its body and content digest. Returns a
  map whose `found` key is false when no record carries that identifier."
  {:signature "(incident_id :string, evidence_id :string) -> :map"}
  [incident-id evidence-id]
  (unwrap
    (tool/evidence.get {"incident_id" incident-id "evidence_id" evidence-id})))

(defn resolve-citations
  "Resolve cited evidence identifiers and digests against the evidence source.

  This is the compiler's own verification step rather than a reporting helper:
  the workflow calls it with the citations a finished draft carries, and
  publication is refused unless both returned lists are empty. `unresolved`
  names citations whose identifier matches no record; `mismatched` names
  citations whose digest differs from the stored record's."
  {:signature
   "(incident_id :string, citations [{evidence_id :string, content_digest :string}]) -> {checked :int, unresolved [:string], mismatched [:string]}"}
  [incident-id citations]
  (let [outcomes
        (map
          (fn [citation]
            (let [evidence-id (get citation "evidence_id")
                  record (get-record incident-id evidence-id)]
              (cond
                (not (true? (get record "found")))
                {:kind :unresolved :evidence-id evidence-id}

                (not= (get citation "content_digest")
                      (get-in record ["record" "content_digest"]))
                {:kind :mismatched :evidence-id evidence-id}

                :else
                {:kind :resolved :evidence-id evidence-id})))
          citations)
        of-kind (fn [kind]
                  (vec (map #(get % :evidence-id)
                            (filter #(= kind (get % :kind)) outcomes))))]
    {"checked" (count outcomes)
     "unresolved" (of-kind :unresolved)
     "mismatched" (of-kind :mismatched)}))
