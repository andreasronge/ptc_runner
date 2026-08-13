(ns runs "Question-shaped evidence from completed PtcRunner runs." {:visibility :prompt})

;; The private-history provider composes its correlated canonical trace and
;; private inspection snapshots. Callers ask one of six user questions instead
;; of joining trace events, model records, generated programs, and preludes.
;; Every result is immutable, bounded, and labelled with the provider alias.

(defn- labelled [envelope]
  (assoc (cap/unwrap! envelope) "provider" "private-history"))

(defn list
  "List captured runs. Options may include limit, cursor, run_id, trace_id,
  status, tags, name, model, provider, from, or to. Pass a returned cursor
  unchanged to continue the same immutable capture."
  {:signature "(options :map) -> :map"}
  [options]
  (labelled (tool/private-history.runs options)))

(defn overview
  "Summarize one run, including canonical outcome, private capture metadata,
  and its retained result when available."
  {:signature "(run-id :string) -> :map"}
  [run-id]
  (labelled (tool/private-history.overview {"run_id" run-id})))

(defn activity
  "Read ordered canonical activity plus authorized capability, provider,
  print, and execution-error evidence for one run."
  {:signature "(run-id :string, options :map) -> :map"}
  [run-id options]
  (labelled (tool/private-history.activity (assoc options "run_id" run-id))))

(defn conversation
  "Reconstruct the model conversation and generated programs for one run.
  Ambiguous records are reported explicitly rather than guessed into a turn."
  {:signature "(run-id :string, options :map) -> :map"}
  [run-id options]
  (labelled (tool/private-history.conversation (assoc options "run_id" run-id))))

(defn failure
  "Explain one failed run with diagnostics, exact programs, effective preludes,
  and conservative direct, same-workflow, preceding, or unknown relationships."
  {:signature "(run-id :string, options :map) -> :map"}
  [run-id options]
  (labelled (tool/private-history.failure (assoc options "run_id" run-id))))

(defn source
  "Read the exact generated programs and effective component sources captured
  for one run. Historical effective source is authoritative over current files."
  {:signature "(run-id :string, options :map) -> :map"}
  [run-id options]
  (labelled (tool/private-history.source (assoc options "run_id" run-id))))
