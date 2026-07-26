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

(defn list-runs
  "Read one public run page. Pass nil first, then the returned next_cursor."
  {:signature "(limit :int, cursor :string?) -> :map"}
  [limit cursor]
  (cap/unwrap!
    (tool/history.list-runs
      (cap/with-cursor {"limit" limit} cursor))))

(defn turns
  "Read one sanitized-turn page for a run.

  Turns carry canonical event sequences and counters, not payloads. Cite a
  sequence here, then read the matching private exchange below."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/history.list-turns
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn model-exchanges
  "Read one private model-exchange page for an explicitly granted run.

  Each item pairs one request with its response and carries the correlation ID
  that ties it to a canonical turn."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.model-exchanges
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn capability-calls
  "Read one private capability-exchange page.

  Each item pairs the exact arguments a generated program passed with the result
  it received."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.capability-calls
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn generated-sources
  "Read one generated-program page for an explicitly granted run.

  Items carry the evaluation identity and source hash, so a cited program is
  bound to the evaluation that ran it."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.generated-sources
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn effective-preludes
  "Read one effective-prelude page for an explicitly granted run.

  This is the prelude the run actually compiled, which is the only reliable way
  to tell a prelude defect from a generated-program defect."
  {:signature "(run-id :string, cursor :string?) -> :map"}
  [run-id cursor]
  (cap/unwrap!
    (tool/private-history.effective-preludes
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))

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
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))
