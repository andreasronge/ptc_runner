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
;; opaque, bound to the captured snapshot, and never parsed here. Each facade
;; response labels its installed `provider` alias so a citation can copy both
;; that alias and `snapshot_hash` without guessing which native source backed it.
;; Catalog items, provenance results, and matching effective-prelude results
;; also expose positive `positions` copied from their source records. The trace
;; catalog projects run-started provenance directly, so listing N runs remains
;; one capability call instead of N follow-up turn queries.
;; A history position is a canonical event sequence. A private-history position
;; is the sequence of the cited inspection record; it is not a canonical trace
;; event. Workspace facades use source line numbers.
;;
;; Authority for historical behaviour: `effective-prelude` returns the exact
;; source a run compiled, and that is the only source that explains what the run
;; did. `repo/read-range` shows the repository as it is now. The two disagree
;; whenever a run replaced a component, which is exactly what candidate
;; evaluation does, so a review that reads the workspace copy can describe code
;; that never executed. When the hashes differ, the executed source wins.

(defn- source-page [provider envelope]
  (assoc (cap/unwrap! envelope) "provider" provider))

(defn- positive-positions [values]
  (filterv #(and (integer? %) (pos? %)) values))

(defn- compact-run [run]
  (assoc
    (select-keys
      run
      ["run_id" "trace_id" "status" "terminal_reason" "start_timestamp"
       "stop_timestamp" "duration_ms" "llm_calls" "subordinate_evaluations"
       "workflow_capability_calls" "mission_capability_calls" "error_count"
       "component_overrides" "positions" "complete" "truncated" "source"])
    "workflow_prelude" (get-in run ["workflow_prelude" "hash"])
    "mission_prelude" (get-in run ["mission_prelude" "hash"])))

(defn list-runs
  "Read one public run page. Pass nil first, then only the exact returned
  next_cursor; nil means the catalog is complete. This page is an intermediate
  compact catalog for choosing run IDs, not a final review result.

  Every item carries its own `component_overrides`, so one observation shows
  which runs replaced a component before compiling and which ran the installed
  source unchanged. Its `positions` identifies that run's run-started event for
  citation. That position supports only start-derived provenance such as
  component overrides and prelude identities; use `turns` or `review-seed` for
  outcome, error, and aggregate behavior evidence. Copy the item's provider,
  snapshot_hash, resource, and positions together. An empty component-overrides
  list means unchanged."
  {:signature "(limit :int, cursor :string?) -> :map"}
  [limit cursor]
  (let [page
        (source-page
          "history"
          (tool/history.list-runs
            (cap/with-cursor {"limit" limit} cursor)))
        provider (get page "provider")
        snapshot-hash (get page "snapshot_hash")]
    (assoc page
           "items"
           (mapv (fn [run]
                   (merge (compact-run run)
                          {"provider" provider
                           "snapshot_hash" snapshot-hash
                           "resource" (get run "run_id")}))
                 (get page "items")))))

(defn provenance
  "Read which components a run replaced before compiling, and the bundle hashes
  it froze.

  `list-runs` already carries component overrides, compact prelude hashes, and a
  citation position. Use this narrower query only when the full run-started
  prelude structures are needed. A run that replaced a component did not execute
  the repository's current source, and nothing else in a review distinguishes
  such a run from a baseline one. `positions` identifies the source run-started
  event. An empty `component_overrides` means the run compiled the installed
  components unchanged."
  {:signature "(run-id :string) -> :map"}
  [run-id]
  (let [page (source-page "history" (tool/history.list-turns {"run_id" run-id "limit" 1}))
        started (first (get page "items"))
        data (get started "data")]
    (if (= "run-started" (get started "type"))
      {"run_id" run-id
       "component_overrides" (get data "component_overrides" [])
       "workflow_prelude" (get data "workflow_prelude")
       "mission_prelude" (get data "mission_prelude")
       "provider" (get page "provider")
       "snapshot_hash" (get page "snapshot_hash")
       "resource" run-id
       "positions" [(get started "sequence")]}
      (fail {"error" "no-run-started-event" "run_id" run-id}))))

(defn effective-prelude
  "Read the exact source one run compiled for one component.

  Pages the private record set internally and returns only the matching
  component, so a caller spends one observation instead of a bundle. This is the
  authoritative source for what the run did; a workspace read of the same path
  shows current bytes, which may be different ones. Compare `source_hash` before
  concluding anything about historical behaviour. `positions` identifies the
  matching private prelude-source record.

  A nil `item` means the run never compiled that component."
  {:signature "(run-id :string, component-id :string) -> :map"}
  [run-id component-id]
  (loop [cursor nil]
    (let [page (source-page
                 "private-history"
                 (tool/private-history.effective-preludes
                   (cap/with-cursor {"run_id" run-id "limit" 20} cursor)))
          match (first (filter #(= component-id (get % "component_id"))
                               (get page "items")))
          next-cursor (get page "next_cursor")]
      (cond
        match {"item" match
               "provider" (get page "provider")
               "snapshot_hash" (get page "snapshot_hash")
               "resource" run-id
               "positions" [(get match "sequence")]}
        next-cursor (recur next-cursor)
        :else {"item" nil
               "provider" (get page "provider")
               "snapshot_hash" (get page "snapshot_hash")}))))

(defn turns
  "Read one filtered sanitized-turn page for a run.

  Turns carry canonical event sequences and counters, not payloads. Cite a
  sequence here, then read the matching private exchange below. Filters may
  contain only status, evaluation_id, and capability."
  {:signature "(run-id :string, filters :map?, cursor :string?) -> :map"}
  [run-id filters cursor]
  (let [filters (select-keys (or filters {}) ["status" "evaluation_id" "capability"])
        arguments (merge filters {"run_id" run-id "limit" 20})]
    (source-page
      "history"
      (tool/history.list-turns
        (cap/with-cursor arguments cursor)))))

(defn model-exchanges
  "Read one private model-exchange page for an explicitly granted run.

  Each item pairs one request with its response and carries the correlation ID
  that ties it to a canonical turn."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (source-page
    "private-history"
    (tool/private-history.model-exchanges
      (cap/with-cursor {"run_id" run-id "limit" 1} cursor))))

(defn latest-model-exchange
  "Read the latest exact model exchange in one descending page. The item puts
  the response before the cumulative request transcript so bounded feedback
  shows the model action first. The wrapper carries copy-ready inspection
  record positions for the paired input and output."
  {:signature "(run-id :string) -> :map"}
  [run-id]
  (let [page
        (source-page
          "private-history"
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
     "provider" (get page "provider")
     "snapshot_hash" (get page "snapshot_hash")
     "resource" run-id
     "positions" (positive-positions
                   [(get item "input_sequence") (get item "output_sequence")])}))

(defn capability-calls
  "Read one private capability-exchange page.

  Each item pairs the exact arguments a generated program passed with the result
  it received."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (source-page
    "private-history"
    (tool/private-history.capability-calls
      (cap/with-cursor {"run_id" run-id "limit" 1} cursor))))

(defn generated-sources
  "Read one generated-program page for an explicitly granted run.

  Items carry the evaluation identity and source hash, so a cited program is
  bound to the evaluation that ran it."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (source-page
    "private-history"
    (tool/private-history.generated-sources
      (cap/with-cursor {"run_id" run-id "limit" 1} cursor))))

(defn latest-generated-source
  "Read the latest generated program with copy-ready inspection coordinates."
  {:signature "(run-id :string) -> :map"}
  [run-id]
  (let [page
        (source-page
          "private-history"
          (tool/private-history.generated-sources
            {"run_id" run-id "limit" 1 "order" "desc"}))
        item (first (get page "items"))]
    {"item" item
     "provider" (get page "provider")
     "snapshot_hash" (get page "snapshot_hash")
     "resource" run-id
     "positions" (positive-positions [(get item "sequence")])}))

(defn review-seed
  "Collect the bounded initial evidence for one failed run in one evaluation.

  Each underlying source read remains a distinct audited capability call. The
  compact result includes the exact latest model response but leaves its
  cumulative request transcript to latest-model-exchange, so a normal review
  does not front-load the complete conversation. Each of model_action, program,
  and trace_errors carries its own provider, snapshot_hash, resource, and
  positive positions when that evidence exists."
  {:signature "(run-id :string) -> :map"}
  [run-id]
  (let [exchange (latest-model-exchange run-id)
        item (get exchange "item")
        program (latest-generated-source run-id)
        trace-errors (turns run-id {"status" "error"} nil)]
    {"model_action"
     {"capability_id" (get item "capability_id")
      "input_sequence" (get item "input_sequence")
      "output_sequence" (get item "output_sequence")
      "response" (get item "response")
      "run_id" (get item "run_id")
      "provider" (get exchange "provider")
      "snapshot_hash" (get exchange "snapshot_hash")
      "trace_id" (get item "trace_id")
      "resource" (get exchange "resource")
      "positions" (get exchange "positions")}
     "program" program
     "trace_errors"
     (assoc trace-errors
            "resource" run-id
            "positions"
            (positive-positions
              (mapv #(get % "sequence") (get trace-errors "items"))))}))

(defn effective-preludes
  "Read one effective-prelude page for an explicitly granted run.

  This is the prelude the run actually compiled, which is the only reliable way
  to tell a prelude defect from a generated-program defect. Each item's
  sha256-prefixed source_hash is directly usable as a candidate
  base_source_hash."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (source-page
    "private-history"
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
  (source-page
    "private-history"
    (tool/private-history.provider-exchanges
      (cap/with-cursor {"run_id" run-id "limit" 1} cursor))))
