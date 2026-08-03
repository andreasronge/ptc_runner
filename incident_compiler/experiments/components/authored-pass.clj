(ns authored
  "Model-authored retrieval: the model writes the gathering program, then it runs.

  The `oneshot` arm proves retrieval can be a program rather than a sequence of
  model turns, but that program is written by hand and parameterised by string
  substitution. This arm moves the authorship: one model call writes the
  program, `kernel/eval-source` runs it in the bounded mission environment, and
  everything downstream — the single report call, citation resolution, the one
  correction turn — is identical to `oneshot`, so the only variable is who wrote
  the retrieval.

  The authoring prompt deliberately names no strategy. It states the goal and
  hands over the mission's own frozen tool context; what the program does is the
  measurement, so telling it to fetch everything would answer the question for
  it. Authoring failures fail closed and are counted separately from report
  failures: an unrunnable program is a fact about this arm, not something to
  paper over with a fallback."
  {:visibility :prompt
   :failure-kinds ["unresolved-citations" "malformed-report" "authoring-failed"]
   :annotations {"citations-verified" ["checked" "unresolved" "mismatched"]
                 "attempts" ["passes" "corrected"]
                 "authoring" ["program-ran" "eval-failed" "records" "repaired"]}})

(defn- strip-fence [content]
  (let [trimmed (str/trim (str content))]
    (if (str/starts-with? trimmed "```")
      (str/trim (str/replace (str/replace trimmed "```clojure" "") "```" ""))
      trimmed)))

(defn- authoring-prompt [incident-id format context rejection]
  (str "Write one program that gathers the evidence needed to compile a report\n"
       "for incident \"" incident-id "\", to be rendered as \"" format "\".\n\n"
       "It runs in this environment. These are the only functions it may call:\n\n"
       context
       (if (nil? rejection)
         ""
         (str "\n\nA previous attempt was rejected before it ran:\n" rejection
              "\nReturn a corrected program."))
       "\n\nRules for the program:\n"
       "- It is one expression, evaluated once. There is no conversation and no\n"
       "  second attempt: whatever it returns is all the evidence the report is\n"
       "  written from.\n"
       "- It must finish by calling (return X), where X is a vector of evidence\n"
       "  record maps. A record map is what get-record puts under \"record\".\n"
       "- Each record it returns must keep the fields it came with, including\n"
       "  \"evidence_id\" and \"content_digest\" — the report cites both, and a\n"
       "  citation that does not match the stored record is refused.\n"
       "- Clojure-style syntax. Use let, map, mapv, filter, reduce, get, concat.\n\n"
       "Return the program text and nothing else — no prose, no code fence."))

(defn- author-program [incident-id format rejection]
  (let [response (llm/request
                   {"system" "You write one program and return its source text, nothing else."
                    "messages" [{"role" "user"
                                 "content" (authoring-prompt
                                             incident-id format
                                             (kernel/mission-model-context)
                                             rejection)}]})
        content (get response "content")]
    (if (string? content)
      (strip-fence content)
      (fail (result/error :authoring-failed :no-content)))))

(defn- run-program [src repaired]
  (let [ev (kernel/eval-source src)]
    (if (not= :returned (get ev :outcome))
      (do (workflow.event/annotate
            "authoring"
            {"program-ran" 0 "eval-failed" 1 "records" 0 "repaired" repaired})
          (fail (result/error :authoring-failed (get ev :outcome))))
      (let [records (get ev :value)]
        (workflow.event/annotate
          "authoring"
          {"program-ran" 1
           "eval-failed" 0
           "records" (if (sequential? records) (count records) 0)
           "repaired" repaired})
        (if (and (sequential? records) (seq records))
          records
          (fail (result/error :authoring-failed :no-records)))))))

;; `check-source` resolves names against the live mission environment without
;; executing, and costs no evaluation against the mission budget. That makes one
;; repair turn cheap: an authored program that names a function that does not
;; exist is caught and rewritten before it ever runs, rather than spending an
;; evaluation to discover the same thing. A second rejection fails closed, so
;; the annotation still separates "could not write a runnable program" from
;; "wrote one that produced a bad report".
(defn- fetch-records [incident-id format]
  (let [src (author-program incident-id format nil)
        check (kernel/check-source src)]
    (if (= :valid (get check :outcome))
      (run-program src 0)
      (let [detail (get (get check :diagnostic) :message)
            repaired (author-program incident-id format detail)
            recheck (kernel/check-source repaired)]
        (if (= :valid (get recheck :outcome))
          (run-program repaired 1)
          (do (workflow.event/annotate
                "authoring"
                {"program-ran" 0 "eval-failed" 1 "records" 0 "repaired" 1})
              (fail (result/error :authoring-failed
                                  (get (get recheck :diagnostic) :kind)))))))))

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

(defn- correction-prompt [incident-id format records contract detail]
  (str (prompt incident-id format records contract)
       "\n\nA previous attempt was rejected because its citations did not resolve "
       "against the evidence source:\n" detail "\n"
       "Every evidence_id must name a record above, and every content_digest must "
       "be copied exactly from that record. Return the corrected report only."))

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

;; Citations are model-authored, and this arm's program text is too. Both reach
;; the verifier as data rather than as source, so neither can alter the program
;; that checks them.
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

(defn run [input]
  (let [incident-id (get input "incident_id")
        format (or (get input "format") "postmortem")
        contract (kernel/result-contract-description)
        records (fetch-records incident-id format)]
    (workflow.event/annotate "progress" {"stage" "executing"})
    (let [first-report (parse-report (ask incident-id format records contract))
          first-outcome (resolve-outcome incident-id first-report)]
      (if (get first-outcome "ok")
        (do (workflow.event/annotate "attempts" {"passes" 1 "corrected" 0})
            (return first-report))
        (let [retry (parse-report
                      (ask-corrected incident-id format records contract
                                     (get first-outcome "detail")))
              retry-outcome (resolve-outcome incident-id retry)]
          (workflow.event/annotate "attempts" {"passes" 2 "corrected" 1})
          (if (get retry-outcome "ok")
            (return retry)
            (fail (result/error :unresolved-citations
                                {:detail (get retry-outcome "detail")}))))))))
