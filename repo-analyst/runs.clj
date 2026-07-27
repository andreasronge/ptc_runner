(ns runs "Bounded evidence from completed PtcRunner runs." {:visibility :prompt})

;; Two installed sources back this facade. `history` reads canonical trace
;; JSONL, which is public run metadata. `private-history` reads exact private
;; inspection artifacts: model exchanges, generated programs, capability
;; arguments and results, effective preludes, and provider wire records.
;;
;; The split is authority, not convenience. A manifest that selects only
;; `history` can call the first two functions and nothing else; the remaining
;; five require an installation that accepts private inspection data, and the
;; run's result must reach an authorized private sink. Keeping both behind one
;; namespace lets a reviewer follow a slow or repeated public event straight to
;; its exact private exchange without guessing a second facade's name.
;;
;; Every function reads one page. Pass nil first, then the previous response's
;; `next_cursor`; a response with no `next_cursor` is the last page. Cursors are
;; opaque, bound to the captured snapshot, and never parsed here.

(defn- compact-run [run]
  (select-keys
    run
    ["run_id" "trace_id" "status" "terminal_reason" "start_timestamp"
     "stop_timestamp" "duration_ms" "llm_calls" "subordinate_evaluations"
     "workflow_capability_calls" "mission_capability_calls" "error_count"
     "complete" "truncated" "source"]))

(defn list-runs
  "Read one public run page. Pass nil first, then only the exact returned
  next_cursor; nil means the catalog is complete. This page is an intermediate
  compact catalog for choosing run IDs, not a final review result."
  {:signature "(limit :int, cursor :string?) -> :map"}
  [limit cursor]
  (let [page
        (cap/unwrap!
          (tool/history.list-runs
            (cap/with-cursor {"limit" limit} cursor)))]
    (assoc page "items" (map compact-run (get page "items")))))

(defn turns
  "Read one filtered sanitized-turn page for a run.

  Turns carry canonical event sequences and counters, not payloads. Cite a
  sequence here, then read the matching private exchange below. Filters may
  contain only status, evaluation_id, and capability."
  {:signature "(run-id :string, filters :map?, cursor :string?) -> :map"}
  [run-id filters cursor]
  (let [filters (select-keys (or filters {}) ["status" "evaluation_id" "capability"])
        arguments (merge filters {"run_id" run-id "limit" 20})]
    (cap/unwrap!
      (tool/history.list-turns
        (cap/with-cursor arguments cursor)))))

(defn model-exchanges
  "Read one private model-exchange page for an explicitly granted run.

  Each item pairs one request with its response and carries the correlation ID
  that ties it to a canonical turn."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.model-exchanges
      (cap/with-cursor {"run_id" run-id "limit" 1} cursor))))

(defn latest-model-exchange
  "Read the latest exact model exchange in one descending page. The item puts
  the response before the cumulative request transcript so bounded feedback
  shows the model action first."
  {:signature "(run-id :string) -> :map"}
  [run-id]
  (let [page
        (cap/unwrap!
          (tool/private-history.model-exchanges
            {"run_id" run-id "limit" 1 "order" "desc"}))
        item (first (get page "items"))]
    {"item"
     {"capability_id" (get item "capability_id")
      "input_sequence" (get item "input_sequence")
      "output_sequence" (get item "output_sequence")
      "response" (get item "result")
      "run_id" (get item "run_id")
      "trace_id" (get item "trace_id")
      "transcript" (get item "arguments")}
     "snapshot_hash" (get page "snapshot_hash")}))

(defn capability-calls
  "Read one private capability-exchange page.

  Each item pairs the exact arguments a generated program passed with the result
  it received."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.capability-calls
      (cap/with-cursor {"run_id" run-id "limit" 1} cursor))))

(defn generated-sources
  "Read one generated-program page for an explicitly granted run.

  Items carry the evaluation identity and source hash, so a cited program is
  bound to the evaluation that ran it."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.generated-sources
      (cap/with-cursor {"run_id" run-id "limit" 1} cursor))))

(defn latest-generated-source
  "Read the latest generated program and retain its snapshot identity."
  {:signature "(run-id :string) -> :map"}
  [run-id]
  (let [page
        (cap/unwrap!
          (tool/private-history.generated-sources
            {"run_id" run-id "limit" 1 "order" "desc"}))]
    {"item" (first (get page "items"))
     "snapshot_hash" (get page "snapshot_hash")}))

(defn review-seed
  "Collect the bounded initial evidence for one failed run in one evaluation.

  Each underlying source read remains a distinct audited capability call. The
  compact result includes the exact latest model response but leaves its
  cumulative request transcript to latest-model-exchange, so a normal review
  does not front-load the complete conversation."
  {:signature "(run-id :string) -> :map"}
  [run-id]
  (let [exchange (latest-model-exchange run-id)
        item (get exchange "item")]
    {"model_action"
     {"capability_id" (get item "capability_id")
      "input_sequence" (get item "input_sequence")
      "output_sequence" (get item "output_sequence")
      "response" (get item "response")
      "run_id" (get item "run_id")
      "snapshot_hash" (get exchange "snapshot_hash")
      "trace_id" (get item "trace_id")}
     "program" (latest-generated-source run-id)
     "trace_errors" (turns run-id {"status" "error"} nil)}))

(defn effective-preludes
  "Read one effective-prelude page for an explicitly granted run.

  This is the prelude the run actually compiled, which is the only reliable way
  to tell a prelude defect from a generated-program defect."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.effective-preludes
      (cap/with-cursor {"run_id" run-id "limit" 1} cursor))))

(defn provider-exchanges
  "Read one private provider-wire page for an explicitly granted run.

  Items carry the bounded JSON-RPC request and response bodies behind a
  capability call, paired by request identity, with credentials and transport
  headers excluded. This is what distinguishes a provider fault from an agent
  fault."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.provider-exchanges
      (cap/with-cursor {"run_id" run-id "limit" 1} cursor))))
