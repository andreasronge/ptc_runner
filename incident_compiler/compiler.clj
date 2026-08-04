(ns incident.compiler
  "Compiles incident evidence into a report whose claims resolve to evidence."
  {:visibility :prompt
   ;; The closed vocabularies this namespace emits. Declared beside the
   ;; `fail` and `annotate` calls below so a canonical trace can name a
   ;; refusal and carry its counts without either drifting from the code.
   :failure-kinds ["unresolved-citations"
                   "citation-verification-refused"
                   "citation-verification-failed"]
   :annotations {"citations-verified" ["checked" "unresolved" "mismatched"]}})

(defn- result-shape []
  (let [description (kernel/result-contract-description)]
    (if (and (string? description) (not (blank? description)))
      description
      (fail (result/error :invalid-prompt :missing-result-contract)))))

(defn- task-text [incident-id format]
  (str/join
    "\n"
    ["You are compiling an evidence report for one incident."
     (str "The incident identifier is \"" incident-id "\".")
     (str "The requested output template is \"" format "\".")
     ""
     "Method:"
     "1. List the available evidence sources, then search them. Read the body of"
     "   every record you intend to rely on before you rely on it."
     "   A search returns a page, not an answer. It reports how many records"
     "   `matched` your filter and whether the page it returned was `truncated`."
     "   Until the records you hold account for every match, you are reading a"
     "   subset, and a report compiled from a subset is wrong even when every"
     "   citation in it resolves."
     "2. Fetch the records once and bind them with def, for example"
     "   (def records (mapv #(incident.evidence/get-record ID %) ids))."
     "   Definitions persist across turns. Re-running the search and refetching"
     "   every record on each turn wastes the turn budget and will exhaust it"
     "   before you finish."
     "3. Build the timeline from what records state, not from what you expect."
     "4. Separate what the evidence shows from what it merely suggests. A"
     "   statement belongs in observed_facts only if a record states it. Anything"
     "   inferred belongs in hypotheses, with its confidence and with any records"
     "   that contradict it listed alongside those that support it."
     "5. Where the evidence does not answer a question that matters, record an"
     "   open question naming the evidence that would answer it. Do not close a"
     "   gap by assuming what the missing record would have said."
     "6. Correlation in time is not causation. If two events are close together,"
     "   say so as an observation and test it as a hypothesis."
     "7. Abstention is an outcome, not a failure. If what you retrieved does not"
     "   let you say what the incident was, return the insufficient_evidence"
     "   shape — a reason and the open questions it leaves — rather than a report"
     "   assembled from whatever happens to be present. Do not abstain where the"
     "   evidence does support a report, however partial that report has to be."
     ""
     "Citations:"
     "Every entry in timeline, observed_facts, and hypotheses carries citations."
     "A citation is {\"evidence_id\": ..., \"content_digest\": ...} copied exactly"
     "from a record you retrieved. Publication is refused if any citation names a"
     "record that does not exist or carries a digest that does not match, so do"
     "not construct, guess, or edit a digest."
     ""
     "Output contract. Return exactly one generated shape below. A ? after a"
     "field name means that field is optional. Add no keys the shape does not name:"
     (result-shape)
     "confidence is one of \"low\", \"medium\", \"high\". contradicting_citations and"
     "an open question's citations may be omitted; every other key is required."
     "A key the generated shape does not list is rejected, so add nothing outside it."]))

(defn- agent-config [input]
  (let [requested (get input "agent")]
    (if (map? requested) requested {})))

(defn- section-citations [items keys]
  (mapcat
    (fn [item]
      (mapcat (fn [key] (or (get item key) [])) keys))
    (or items [])))

(defn- report-citations [report]
  (distinct
    (concat
      (section-citations (get report "timeline") ["citations"])
      (section-citations (get report "observed_facts") ["citations"])
      (section-citations
        (get report "hypotheses")
        ["supporting_citations" "contradicting_citations"])
      (section-citations (get report "open_questions") ["citations"]))))

;; The verification program is application source, but the identifiers spliced
;; into it arrive from the model. Restricting both to a closed alphabet before
;; interpolation is what makes the splice safe: neither can carry a quote,
;; backslash, or parenthesis, so neither can extend the program being built.
(defn- safe-identifier? [value]
  (and (string? value)
       (some? (re-matches #"[a-z0-9][a-z0-9._-]{0,127}" value))))

(defn- safe-digest? [value]
  (and (string? value)
       (some? (re-matches #"sha256:[0-9a-f]{64}" value))))

(defn- safe-citation? [citation]
  (and (map? citation)
       (safe-identifier? (get citation "evidence_id"))
       (safe-digest? (get citation "content_digest"))))

(defn- citation-literal [citation]
  (str "{\"evidence_id\" \"" (get citation "evidence_id")
       "\" \"content_digest\" \"" (get citation "content_digest") "\"}"))

(defn- verification-source [incident-id citations]
  (str "(return (incident.evidence/resolve-citations \"" incident-id "\" ["
       (str/join " " (map citation-literal citations))
       "]))"))

(defn- resolve-citations [incident-id citations]
  (let [evaluation (kernel/eval-source (verification-source incident-id citations))]
    (if (= :returned (get evaluation :outcome))
      (get evaluation :value)
      (fail (result/error :citation-verification-failed (get evaluation :outcome))))))

(defn- verified [incident-id report]
  (let [citations (report-citations report)]
    (cond
      (empty? citations)
      (fail (result/error :citation-verification-refused :no-citations))

      (not (every? safe-citation? citations))
      (fail (result/error :citation-verification-refused :malformed-citation))

      :else
      (let [_ (workflow.event/annotate "progress" {"stage" "validating"})
            resolution (resolve-citations incident-id citations)
            unresolved (get resolution "unresolved")
            mismatched (get resolution "mismatched")
            grounded? (and (empty? unresolved) (empty? mismatched))]
        ;; Counts only. The identifiers stay in the failure value; how many
        ;; citations were checked and how many failed is what a reader needs
        ;; to tell one fabricated reference from a wholly invented corpus.
        (workflow.event/annotate
          "citations-verified"
          {"checked" (get resolution "checked")
           "unresolved" (count unresolved)
           "mismatched" (count mismatched)})
        (workflow.event/annotate
          "progress"
          {"stage" (if grounded? "completed" "failed")})
        (if grounded?
          report
          (fail (result/error :unresolved-citations
                              {:unresolved (get resolution "unresolved")
                               :mismatched (get resolution "mismatched")})))))))

(defn run
  "Compiles one incident into a contract-valid report.

  The agent loop validates each model-authored terminal candidate against the
  manifest result contract while a correction turn can still run, so the value
  reaching here is already structurally sound. What it is not yet is grounded:
  the contract can require that a citation exists and is well shaped, never
  that the record it names is real. Resolving every citation against the
  evidence source is this entry's own step, and it fails closed."
  [input]
  (let [incident-id (get input "incident_id")
        format (or (get input "format") "postmortem")]
    (if (not (safe-identifier? incident-id))
      (fail (result/error :invalid-input :incident-id))
      (let [report (agent.core/run-result-value
                     (task-text incident-id format)
                     (agent-config input))]
        (cond
          ;; The contract requires `incident_id` to be a non-empty string and
          ;; nothing more, so a structurally valid answer can name a different
          ;; incident. Citation resolution would not catch it — it resolves
          ;; against the requested incident either way — and the abstention
          ;; branch below skips that check entirely.
          (not= incident-id (get report "incident_id"))
          (fail (result/error :citation-verification-refused :foreign-incident))

          (= "insufficient_evidence" (get report "status"))
          (return report)

          :else
          (return (verified incident-id report)))))))
