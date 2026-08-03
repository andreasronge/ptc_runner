(ns stress "Does fit/handles? say no when the doc's own disqualifiers are present?"
  {:visibility :prompt})

(defn- case-of [label proj]
  {"case" label
   "fit" (fit/handles? "singleshot/run"
                       (str "Compile an incident into a report where every claim cites a real "
                            "evidence record, observed facts are separated from hypotheses, "
                            "and unanswered questions are recorded.")
                       proj)})

(defn run [_input]
  (let [small {"record_count" 12 "total_body_chars" 2273 "longest_body_chars" 260
               "distinct_sources" 6 "records_citing_other_records" 0
               "earliest" "2026-05-14T09:09Z" "latest" "2026-05-14T09:58Z"
               "titles" ["logs: TLS handshake failure" "deploy: release 2026.5.14-a"]}
        huge (assoc small "record_count" 4200 "total_body_chars" 1850000
                    "longest_body_chars" 41000 "distinct_sources" 31)
        tangled (assoc small "records_citing_other_records" 11
                       "titles" ["chat: see log-8812 before concluding"
                                 "log-8812: contradicts alert-4471, check deploy-2291"
                                 "deploy-2291: superseded by the record chat-1180 references"])]
    (return {"small" (case-of "small" small)
             "huge" (case-of "huge" huge)
             "tangled" (case-of "tangled" tangled)})))
