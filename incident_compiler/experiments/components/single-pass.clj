(ns oneshot
  "Single-shot incident compiler: fetch deterministically, ask once, verify.

  No agent loop. The retrieval is a program, not a sequence of model turns,
  and the model is asked for the whole report in one exchange — the shape a
  general coding agent uses when it reads a directory and writes a file."
  {:visibility :prompt
   :failure-kinds ["unresolved-citations" "citation-verification-refused"
                   "malformed-report"]
   :annotations {"citations-verified" ["checked" "unresolved" "mismatched"]
                 "attempts" ["passes" "corrected"]}})

(def fetch-src
  (str "(let [found (get (incident.evidence/search INCIDENT nil nil 50) \"records\")\n"
       "      ids (map (fn [r] (get r \"evidence_id\")) found)]\n"
       "  (return (mapv (fn [id] (get (incident.evidence/get-record INCIDENT id) \"record\")) ids)))"))

(defn- fetch-records [incident-id]
  (let [src (str/replace fetch-src "INCIDENT" (str "\"" incident-id "\""))
        ev (kernel/eval-source src)]
    (if (= :returned (get ev :outcome))
      (get ev :value)
      (fail (result/error :citation-verification-failed (get ev :outcome))))))

(defn- prompt [incident-id format records contract]
  (str "You are compiling an evidence report for incident \"" incident-id "\".\n"
       "Requested output template: \"" format "\".\n\n"
       "Every record below is the complete evidence. Fields: evidence_id,\n"
       "observed_at, source, title, body, content_digest.\n\n"
       (json/generate-string records)
       "\n\nReturn ONE JSON object and nothing else — no prose, no code fence.\n"
       "It must satisfy this contract:\n" contract "\n\n"
       "Rules:\n"
       "- Every entry in timeline, observed_facts, and every hypothesis citation\n"
       "  carries citations of the form {\"evidence_id\": ..., \"content_digest\": ...},\n"
       "  copied exactly from the record it refers to. Never invent either field.\n"
       "- observed_facts only for what a record states. Anything inferred is a\n"
       "  hypothesis, with contradicting records listed alongside supporting ones.\n"
       "- Where the evidence does not answer a question that matters, record an\n"
       "  open question naming the evidence that would answer it.\n"
       "- Correlation in time is not causation.\n"))

(defn- ask [incident-id format records contract]
  (let [response (llm/request {"system" "You return one JSON object and nothing else."
                               "messages" [{"role" "user"
                                            "content" (prompt incident-id format records contract)}]})
        content (get response "content")]
    (if (string? content)
      content
      (fail (result/error :malformed-report :no-content)))))

(defn- ask-corrected [incident-id format records contract detail]
  (let [response (llm/request
                   {"system" "You return one JSON object and nothing else."
                    "messages" [{"role" "user"
                                 "content" (correction-prompt incident-id format records
                                                              contract detail)}]})
        content (get response "content")]
    (if (string? content) content (fail (result/error :malformed-report :no-content)))))

(defn- parse-report [content]
  (let [trimmed (str/trim content)
        body (if (str/starts-with? trimmed "```")
               (str/trim (str/replace (str/replace trimmed "```json" "") "```" ""))
               trimmed)
        parsed (json/parse-string body)]
    (if (map? parsed)
      parsed
      (fail (result/error :malformed-report :not-an-object)))))

(defn- citations-of [report]
  (distinct
    (concat
      (mapcat (fn [i] (or (get i "citations") [])) (or (get report "timeline") []))
      (mapcat (fn [i] (or (get i "citations") [])) (or (get report "observed_facts") []))
      (mapcat (fn [h] (concat (or (get h "supporting_citations") [])
                              (or (get h "contradicting_citations") [])))
              (or (get report "hypotheses") [])))))

(defn- citation-literal [c]
  (str "{\"evidence_id\" \"" (get c "evidence_id")
       "\" \"content_digest\" \"" (get c "content_digest") "\"}"))

(defn- resolve-outcome [incident-id report]
  (let [cites (citations-of report)]
    (if (empty? cites)
      {"ok" false "detail" "the report carried no citations"}
      (let [src (str "(return (incident.evidence/resolve-citations \"" incident-id "\" ["
                     (str/join " " (map citation-literal cites)) "]))")
            ev (kernel/eval-source src)]
        (if (not= :returned (get ev :outcome))
          {"ok" false "detail" "citation resolution did not return"}
          (let [res (get ev :value)
                unresolved (get res "unresolved")
                mismatched (get res "mismatched")]
            (workflow.event/annotate
              "citations-verified"
              {"checked" (get res "checked")
               "unresolved" (count unresolved)
               "mismatched" (count mismatched)})
            {"ok" (and (empty? unresolved) (empty? mismatched))
             "detail" (str "unresolved evidence ids: " (str/join ", " unresolved)
                           "; digests not matching the stored record: "
                           (str/join ", " mismatched))}))))))

(defn- verify [incident-id report]
  (let [cites (citations-of report)]
    (if (empty? cites)
      (fail (result/error :citation-verification-refused :no-citations))
      (let [src (str "(return (incident.evidence/resolve-citations \"" incident-id "\" ["
                     (str/join " " (map citation-literal cites)) "]))")
            ev (kernel/eval-source src)]
        (if (not= :returned (get ev :outcome))
          (fail (result/error :citation-verification-failed (get ev :outcome)))
          (let [res (get ev :value)
                unresolved (get res "unresolved")
                mismatched (get res "mismatched")]
            (workflow.event/annotate
              "citations-verified"
              {"checked" (get res "checked")
               "unresolved" (count unresolved)
               "mismatched" (count mismatched)})
            (if (and (empty? unresolved) (empty? mismatched))
              report
              (fail (result/error :unresolved-citations
                                  {:unresolved unresolved :mismatched mismatched})))))))))

(defn- correction-prompt [incident-id format records contract detail]
  (str (prompt incident-id format records contract)
       "\n\nA previous attempt was rejected because its citations did not resolve "
       "against the evidence source:\n" detail "\n"
       "Every evidence_id must name a record above, and every content_digest must "
       "be copied exactly from that record. Return the corrected report only."))

(defn run [input]
  (let [incident-id (get input "incident_id")
        format (or (get input "format") "postmortem")
        contract (kernel/result-contract-description)
        records (fetch-records incident-id)]
    (workflow.event/annotate "progress" {"stage" "executing"})
    (let [first-report (parse-report (ask incident-id format records contract))
          first-outcome (resolve-outcome incident-id first-report)]
      (if (get first-outcome "ok")
        (do (workflow.event/annotate "attempts" {"passes" 1 "corrected" 0})
            (return first-report))
        ;; One correction turn, seeded with the specific citations that failed.
        ;; This is the loop's only structural advantage over a single pass; the
        ;; cost is one extra call, against the loop's twelve to sixteen.
        (let [retry (parse-report
                      (ask-corrected incident-id format records contract
                                     (get first-outcome "detail")))
              retry-outcome (resolve-outcome incident-id retry)]
          (workflow.event/annotate "attempts" {"passes" 2 "corrected" 1})
          (if (get retry-outcome "ok")
            (return retry)
            (fail (result/error :unresolved-citations
                                {:detail (get retry-outcome "detail")}))))))))
