(ns oneshot
  "Single-shot incident compiler: fetch deterministically, ask once, verify.

  No agent loop. The retrieval is a program, not a sequence of model turns,
  and the model is asked for the whole report in one exchange — the shape a
  general coding agent uses when it reads a directory and writes a file."
  {:visibility :prompt
   :failure-kinds ["unresolved-citations" "citation-verification-failed"
                   "malformed-report"]
   :annotations {"citations-verified" ["checked" "unresolved" "mismatched"]
                 "attempts" ["passes" "corrected"]
                 "coverage" ["gathered" "available" "complete"]}})

;; The program is a constant. The incident id reaches it as data at
;; `data/params`, never as text substituted into the source, so there is no
;; escaping to get right and no value that can change the program's shape.
(def fetch-src
  (str "(let [inc (get data/params \"incident_id\")\n"
       "      found (get (incident.evidence/search inc nil nil 50) \"records\")\n"
       "      ids (map (fn [r] (get r \"evidence_id\")) found)]\n"
       "  (return (mapv (fn [id] (get (incident.evidence/get-record inc id) \"record\")) ids)))"))

(defn- fetch-records [incident-id]
  (let [ev (kernel/eval-source-with fetch-src {"incident_id" incident-id})]
    (if (= :returned (get ev :outcome))
      (get ev :value)
      (fail (result/error :citation-verification-failed (get ev :outcome))))))

;; What the incident actually holds, asked of the source rather than assumed.
;; `list-sources` reports `record_count`, so this is one capability call. The
;; hand-written program above is not changed here: the question is whether a
;; report told it is working from a fraction behaves differently, not whether a
;; better fetch would help — it obviously would.
(def coverage-src
  (str "(let [inc (get data/params \"incident_id\")\n"
       "      sources (get (incident.evidence/list-sources inc) \"sources\")]\n"
       "  (return (reduce + 0 (mapv (fn [s] (get s \"record_count\")) sources))))"))

(defn- gather [incident-id]
  (let [records (fetch-records incident-id)
        ev (kernel/eval-source-with coverage-src {"incident_id" incident-id})
        available (if (= :returned (get ev :outcome)) (get ev :value) 0)]
    {"records" records
     "available" available
     "complete" (or (= 0 available) (>= (count records) available))}))

(defn- coverage-sentence [gathered]
  (if (get gathered "complete")
    "Every record below is the complete evidence."
    (str "The records below are " (count (get gathered "records")) " of the "
         (get gathered "available") " records this incident holds. "
         "You are not seeing all of the evidence, and retrieval could not be "
         "made complete.")))

(defn- prompt [incident-id format gathered contract]
  (str "You are compiling an evidence report for incident \"" incident-id "\".\n"
       "Requested output template: \"" format "\".\n\n"
       (coverage-sentence gathered) " Fields: evidence_id,\n"
       "observed_at, source, title, body, content_digest.\n\n"
       (json/generate-string (get gathered "records"))
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

(defn- ask [incident-id format gathered contract]
  (let [response (llm/request {"system" "You return one JSON object and nothing else."
                               "messages" [{"role" "user"
                                            "content" (prompt incident-id format gathered contract)}]})
        content (get response "content")]
    (if (string? content)
      content
      (fail (result/error :malformed-report :no-content)))))

(defn- ask-corrected [incident-id format gathered contract detail]
  (let [response (llm/request
                   {"system" "You return one JSON object and nothing else."
                    "messages" [{"role" "user"
                                 "content" (correction-prompt incident-id format gathered
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

;; Citations are model-authored. Projecting them to exactly the two declared
;; fields and passing them as data means a hostile `evidence_id` stays a string:
;; it is compared against the evidence source, never parsed as part of the
;; program that does the comparing.
(defn- citation-value [c]
  {"evidence_id" (get c "evidence_id")
   "content_digest" (get c "content_digest")})

(def resolve-src
  (str "(return (incident.evidence/resolve-citations (get data/params \"incident_id\")\n"
       "                                             (get data/params \"citations\")))"))

(defn- resolve-outcome [incident-id report]
  (let [cites (citations-of report)]
    (if (empty? cites)
      {"ok" false "detail" "the report carried no citations"}
      (let [ev (kernel/eval-source-with
                 resolve-src
                 {"incident_id" incident-id
                  "citations" (mapv citation-value cites)})]
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


(defn- correction-prompt [incident-id format gathered contract detail]
  (str (prompt incident-id format gathered contract)
       "\n\nA previous attempt was rejected because its citations did not resolve "
       "against the evidence source:\n" detail "\n"
       "Every evidence_id must name a record above, and every content_digest must "
       "be copied exactly from that record. Return the corrected report only."))

(defn run [input]
  (let [incident-id (get input "incident_id")
        format (or (get input "format") "postmortem")
        contract (kernel/result-contract-description)
        gathered (gather incident-id)]
    (workflow.event/annotate "progress" {"stage" "executing"})
    (workflow.event/annotate
      "coverage"
      {"gathered" (count (get gathered "records"))
       "available" (get gathered "available")
       "complete" (if (get gathered "complete") 1 0)})
    (let [first-report (parse-report (ask incident-id format gathered contract))
          first-outcome (resolve-outcome incident-id first-report)]
      (if (get first-outcome "ok")
        (do (workflow.event/annotate "attempts" {"passes" 1 "corrected" 0})
            (return first-report))
        ;; One correction turn, seeded with the specific citations that failed.
        ;; This is the loop's only structural advantage over a single pass; the
        ;; cost is one extra call, against the loop's twelve to sixteen.
        (let [retry (parse-report
                      (ask-corrected incident-id format gathered contract
                                     (get first-outcome "detail")))
              retry-outcome (resolve-outcome incident-id retry)]
          (workflow.event/annotate "attempts" {"passes" 2 "corrected" 1})
          (if (get retry-outcome "ok")
            (return retry)
            (fail (result/error :unresolved-citations
                                {:detail (get retry-outcome "detail")}))))))))
