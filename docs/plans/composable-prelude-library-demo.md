# Composable Prelude Library Demo — Overview Plan

## Status

Proposed next experiment after the MCP-native editing-mechanism run in the
external `../../ptc-bench-comparison` repo.

The completed 2026-07-03 run proved the plumbing claim: separate MCP-only model
processes, human-gated at every stage, completed analyst -> proposer ->
reviewer -> editor -> validator and ended in a real `PreludeStore` write that
fresh validation attached and exercised. Its convergence result was useful but
partial: the loop independently derived delta-only authoring,
substrate-side source mutation, and checksum verification, but did not derive
the sealed form-keyed `prelude/edit` design, read-side form introspection, or
staleness guard. One position-blind retry changed a string literal while
fixing a compile error, which is itself evidence for form-aware editing.

This plan uses the now-implemented `prelude/edit`, `prelude/form`, and declared
prelude dependencies to test the next North Star claim: preludes should behave
like composable capability libraries, not monolithic prompt bundles.

Minimum implementation pin for the external run is `5055deac`, which adds
read-only prelude introspection and session-mode `catalog_ops`. Later pins are
fine, but the run must verify both capabilities through MCP before model
stages.

## Objective

Demonstrate and measure a split-prelude workflow:

- `paged_base`: pagination, bounded folding, sampling, profiling, and generic
  table/data helpers.
- `paged_audit`: audit workflow helpers and guidance that depend on
  `paged_base` through `requires_preludes`.

Then run the self-improvement loop over evidence and ask whether it proposes a
change to the correct layer: base/library vs. audit/workflow.

The value claim is not merely that two preludes can attach. That is already
covered by declared dependencies. The value claim is that a model can inspect a
layered capability surface, understand which layer owns a missing or costly
behavior, and author a change through the typed prelude surface without
copy-paste growth.

## Preconditions

1. Pin the current `ptc_runner` commit at run design time and record it in the
   external run directory. Do not upgrade mid-run.
2. Rerun Stage 0 preflight at that pin:
   - HTTP MCP server starts with sessions and prelude writes enabled.
   - one process writes a throwaway prelude;
   - a fresh process attaches and calls it;
   - a declared-dependency smoke writes `base@1`, writes `audit@1` with
     `requires_preludes`, then fresh-attaches `audit` only and observes the
     transitive base pin.
3. Confirm lifecycle evidence is preserved:
   - per-boot server logs or append-only logs;
   - boot ledger with pid, commit, seed checksum, and turn-log path;
   - per-stage turn-log snapshots;
   - inter-stage store fingerprints.
4. Confirm session-mode `catalog_ops` appears in MCP turn logs. Discovery-cost
   measurement must use the structural ledger, not inference from program text.
5. Confirm read-only MCP sessions with a configured prelude store and no
   separate runtime prelude expose `prelude/form`, `prelude/forms`,
   `prelude/form-deps`, and related read introspection without exposing
   `prelude/write`, `prelude/edit`, or `prelude/set-default`.

## Experiment Shape

### Stage 0 — Preflight

Fresh server/store at the pinned commit. Validate independent write/attach,
declared prelude dependencies, `prelude/edit`, `prelude/form`, and
`prelude/forms` through MCP.

Also validate stale-parent behavior through MCP. At `5055deac`, `prelude/write`
honors `parent_checksum`/`parent_version` and fails stale writes closed, while
`prelude/edit` edits the current candidate and does not expose caller-supplied
expected-base fields.

### Stage 1 — Split Prelude Setup

Human-seed the split prelude pair for this run:

- `paged_base@1` contains reusable data access and bounded aggregation.
- `paged_audit@1` declares `requires_preludes ["paged_base"]` and contains
  only workflow-level helpers/cues.

Keep public surfaces intentionally small. The M2 observability prelude result
showed that broad helper surfaces can cost more in discovery than they save.
Record the public-export budget and the reason each export is public.

### Stage 2 — Analyst Evidence

Fresh MCP-only process reads prior run evidence through an evidence upstream.
The evidence should include:

- the completed editing-mechanism run summary;
- Stage 4/5 turn metrics: 15 evals before first write, one retry, one
  position-blind string-literal deviation;
- M2 discovery-cost evidence, especially helper-surface overhead and print-only
  / preview-driven waste;
- split-prelude export surfaces and form metadata via read-only prelude
  introspection.

Recommendation sections from prior notes should be redacted before serving
evidence to the proposer. The A/B table and observed findings are evidence; the
operator's "what to do next" bullets would steer the layer choice.

Hold the `prelude/edit` expected-base verifier finding out of proposer evidence
by default. Include it only if the pre-registered answer key explicitly treats
the missing expected-base contract as an acceptable
`ptc_runner`-engineering-request answer.

The analyst separates observed facts from proposed changes.

### Stage 3 — Proposer

Fresh read-only MCP-only process reads analyst evidence and inspects both
preludes.
The proposal must classify the target layer:

- base/library change;
- audit/workflow change;
- documentation/surface-trimming change;
- `ptc_runner` engineering request.

The proposal must explain why the change belongs in that layer and which
existing forms it reuses.

Before Stage 2 starts, pre-register the expected correct layer and rationale in
the run directory. The Stage 2 evidence bundle should support more than one
plausible layer so layer selection is not dictated by a single highlighted
finding.

### Stage 4 — Reviewer

Fresh MCP-only reviewer accepts, rejects, or requests revision. Review focus:

- correct layer;
- no copy-paste growth across preludes;
- no benchmark-specific leakage;
- evidence-backed claim about discovery cost or editing cost;
- feasibility under current `prelude/edit` and dependency semantics.
- stale-base risk.

### Stage 5 — Editor

Fresh MCP-only write-capable process uses `prelude/edit` rather than
full-source `prelude/write` or in-session string splicing.

Required measurements:

- evals before first edit/write attempt;
- compile retries;
- edit result checksum and base version;
- touched form names;
- whether `prelude/edit` prevented the prior position-blind retry class.

If the accepted edit changes `paged_base`, the run must also perform a gated
companion re-pin of `paged_audit`; otherwise `paged_audit@1` continues to
attach the old base checksum and validation can silently test unchanged code.

After any editor write, the orchestrator should compare the edit result's
`base_version` and `parent_checksum` with the prelude version/checksum the
editor last inspected. A mismatch is a stale-prepared-edit event and should
stop at the human gate, because current `prelude/edit` cannot pin an expected
base itself.

### Stage 6 — Validator

Fresh read-only process attaches the changed top-level prelude and validates:

- transitive dependency pins resolve;
- a base-layer change is visible through the top-level audit attach closure
  after the companion re-pin;
- changed behavior works;
- unchanged layer contracts still pass;
- public surface remains trimmed;
- store snapshot/fingerprint matches expected checksums.

## Form-Keyed Epilogue Measurement

Run one small replay against the same historical `reconcile-totals` insertion
used in the 2026-07-03 editing-mechanism run, but this time through
`prelude/edit`.

Compare directly against the prior baseline:

- prior recipe: 15 evals before first write;
- prior retry count: 1;
- prior deviation: position-blind qualifier stripping inside a string literal;
- prior drift: zero out-of-region drift after checksum-verified readback.

Expected value of `prelude/edit`:

- no whole-source or anchor-string authoring;
- touched forms explicit in the edit request/result;
- no source-wide qualifier replacement;
- parent/base checksum visible in the result.

Treat the one-shot replay as qualitative unless repeated 3-5 times. The
structurally guaranteed claims are no whole-source authoring, touched forms in
the edit request/result, and parent checksum visibility.

## Measurements

Primary:

- Correct-layer proposal: did the loop choose `paged_base`, `paged_audit`, docs,
  or a `ptc_runner` request for the right reason, scored against the
  pre-registered key?
- Editing structure: typed edit request, explicit touched forms, no
  whole-source or anchor-string authoring.
- Editing quality: retries and deviations vs. prior baseline of one compile
  retry plus one position-blind string-literal deviation.
- Surface economy: number of public exports and discovery turns before the
  first useful call.
- Validation: fresh attach of dependent prelude succeeds and behavior matches
  expected checks.

Secondary:

- `catalog_ops` count from MCP session turn logs;
- one-shot replay eval count vs. prior baseline of 15, treated as qualitative
  unless repeated 3-5 times;
- print-only / preview-driven turns;
- evidence-reading turns before first substantive analysis;
- whether reviewer detects stale-base or wrong-layer risk.

Staleness probe:

- write version N;
- bump the target prelude to N+1;
- submit a stale `prelude/write` with version N's parent-version/checksum;
- require fail-closed behavior through the stale-base guard.

Do not claim caller-prepared `prelude/edit` staleness unless `ptc_runner` first
adds an explicit expected-base contract to `prelude/edit`; that contract is not
present at `5055deac`.

Non-metrics:

- Bike-share benchmark score. This is a library-composability and editing
  mechanism demo, not a new audit-task performance claim.

## What This Demo Still Does Not Solve

Current baseline after Slice A (`85ffa253`), Slice B (`3c1d0514`), and the
Slice C role-policy implementation:

- the HTTP MCP server has an admin-token-gated live PreludeStore
  snapshot/export surface;
- stateful sessions can stamp structured tags, `log/` can query and aggregate
  turn logs, and `log/counters` preserves unknown-token semantics;
- the `evidence/` prelude can expose curated evidence bundles over static
  fixtures, turn-log projections, counters, and PreludeStore exports;
- stateful sessions can self-declare configured roles, receive exact
  mode/prelude/prelude-store/PTC-tool grants, echo a grant fingerprint, and
  stamp role/grant audit fields into turn logs;
- a process-level outer policy can filter the MCP `tools/list` / `tools/call`
  surface for stage-specific server processes.

The remaining policy-track gaps are:

- no bearer-token-bound role authority yet: sessions can self-declare roles, so
  D3 still needs to bind bearer tokens to roles before this is more than
  harness discipline;
- no projection-scoped MCP HTTP clients yet: D2a fails closed for denied
  credentialed MCP HTTP calls, but D2b is still needed before a restricted role
  can call a credentialed MCP HTTP upstream through its own projected client;
- per-role upstream tool visibility is implemented for stateful sessions:
  projected upstream catalogs, prelude attach/filtering, and `(tool/call ...)`
  dispatch all honor the role's `upstream_tools` grant;
- no native replacement for stage-specific server processes or the external MCP
  tool-filter proxy when one server must present different outer catalogs to
  different credentials;
- no built-in fixture upstream beyond evidence projections over packaged files
  and existing turn logs.

That means the next demo can avoid the old hand-scripted snapshot and evidence
plumbing, but still needs stage-specific server processes or an external proxy
when different roles must see different outer MCP tool catalogs.

## Recommended Independent Implementation Slices

These should land as independent slices. Each slice should have its own tests,
docs, and turn-log/audit story, and none should require the others to be useful.
Slices A-C are implemented; keep their sections as the historical contract and
use D-E as the remaining implementation queue.

### Slice A — Live PreludeStore Admin Snapshot/Export

Goal: make the running HTTP MCP server's volatile prelude store externally
capturable by an operator/harness.

Minimal shape:

- add an operator-only admin surface for store snapshot/export, not a
  model-facing session tool;
- gate the surface behind a deliberately small second token class:
  `--http-admin-token` / `PTC_RUNNER_MCP_HTTP_ADMIN_TOKEN`;
- do not register admin routes at all when the admin token is unset;
- compare the token with a constant-time binary comparison and reject with
  `401`/`403` without logging token bytes;
- expose at least `snapshot` and current-source `export` semantics equivalent
  to the library APIs;
- stamp responses/logs with boot id, commit, `git_dirty`, store fingerprint,
  schema version, and timestamp;
- introduce a pure export-bundle helper, or have the admin route materialize
  the existing seed-directory export into a bounded JSON response;
- keep restore/import out of the first slice unless the auth and rollback story
  is explicit.

Do not make this a general role system. The admin token is an operator escape
hatch for harnesses and should be forward-compatible with Slice D, but it
should not introduce per-role credential semantics.

Suggested endpoints:

```text
GET /admin/prelude-store/snapshot
GET /admin/prelude-store/export
```

Suggested `snapshot` response:

```json
{
  "status": "ok",
  "schema_version": 1,
  "boot_id": "20260704T...",
  "commit": "5055deac",
  "git_dirty": false,
  "store_fingerprint": "sha256:...",
  "created_at": "2026-07-04T12:00:00Z",
  "snapshot": { "...": "PreludeStore.snapshot/1 payload" }
}
```

Suggested `export` response:

```json
{
  "status": "ok",
  "schema_version": 1,
  "boot_id": "20260704T...",
  "commit": "5055deac",
  "git_dirty": false,
  "store_fingerprint": "sha256:...",
  "manifest": {
    "schema_version": 1,
    "store_fingerprint": "sha256:...",
    "entries": []
  },
  "files": [
    {"path": "base.clj", "source": "(ns base) ..."},
    {"path": "audit.clj", "source": "(ns audit) ..."},
    {"path": "audit.deps", "source": "base\n"}
  ]
}
```

The export response must not imply that `PreludeStore.export/3` already returns
this JSON shape. Today the library export writes a seed-compatible directory:
`.clj` source files plus plain `.deps` sidecars for preludes that have
dependencies, one dependency id/ref per line, and a manifest. Dependency-free
preludes do not need empty sidecars. Slice A should either add a pure "export
bundle" function that returns that same content as data, or use the current
directory exporter internally and read back the materialized files under a byte
cap. In both cases, the HTTP payload must include enough source and dependency
sidecar information for a harness to recreate a valid `--prelude-store-seed`
directory without guessing.

The aggregate `store_fingerprint` should be stable across snapshot, export,
and later seed/restore checks. Compute it from sorted current entries, e.g.
`id`, current `version`, and current `checksum` for every id. Gate checks can
then compare one value instead of a whole manifest.

Example external harness flow for snapshot capture:

```bash
curl -H "Authorization: Bearer $ADMIN_TOKEN" \
  http://localhost:4000/admin/prelude-store/snapshot \
  > run-prelude-store.snapshot.json
```

Example preferred experiment restore flow:

```bash
curl -H "Authorization: Bearer $ADMIN_TOKEN" \
  http://localhost:4000/admin/prelude-store/export \
  > run-prelude-store.export.json

# Harness writes the returned files/manifest to a seed directory, then starts a
# fresh server with no hidden process state:
ptc_runner_mcp --sessions --prelude-store-seed ./run-prelude-store-seed
```

Restore-via-restart is already the preferred experiment rollback path:
export current sources, start a fresh BEAM, and seed with
`--prelude-store-seed`. Live restore can wait; a fresh VM is easier to reason
about and gives the gate runner stronger reproducibility evidence.

This should be implemented before relying on multi-stage demos as durable
evidence. Without it, an experiment can mutate the live store successfully but
still require ad hoc BEAM-side access to preserve the exact final state.

Slice A tests:

- routes are absent or return not-found when `--http-admin-token` is unset;
- missing/wrong token cannot snapshot/export and does not leak the token;
- snapshot response includes boot id, commit, `git_dirty`, timestamp, schema,
  and `store_fingerprint`;
- export manifest includes the same `store_fingerprint`;
- exported current sources can seed a fresh server and reproduce the same
  current id/version/checksum set;
- dirty builds are reported honestly so evidence-grade gates can reject them.

### Slice B — Evidence Projection Over Existing Logs

Goal: turn the existing trace-log/introspection machinery into curated evidence
packets for experiments.

This is not a replacement for logging. Logging records what happened:
turns, programs, tool calls, catalog ops, prelude provenance, and session
events. Evidence projection should package selected log data and fixture files
into stable, versioned inputs for model stages.

Minimal shape:

- build an evidence index/projection over turn logs and fixture directories;
- expose stage-oriented reads such as run summary, selected turns, selected
  programs, store fingerprints, and non-answer fixture contents;
- record evidence bundle id/checksum in turn logs when a model stage reads it;
- keep evidence content read-only and redacted/selected before it reaches the
  model, using operator-supplied selection/redaction specs.

The redaction boundary matters. `ptc_runner` should provide packaging
mechanics: select, bound, checksum, serve, and log the read. It should not own
benchmark-specific redaction rules or expected-answer knowledge. Operators
define the evidence bundle contents; the server enforces the declared bundle
contract and records what was served.

Expected outputs and answer keys are operator-only gate inputs, not
model-facing evidence. The evidence upstream may help the harness checksum and
record those files, but a model stage must not be able to call a
`fixture/expected`-style API that reveals the target answer. That keeps the
orchestration layer domain-blind and avoids turning evidence projection into a
benchmark-specific answer service.

Use one paging shape for all new model-facing evidence APIs:

```json
{
  "items": [],
  "next_cursor": null,
  "has_more": false,
  "limit": 50
}
```

Avoid adding new `offset`/`next_offset`/token-at variants in Slice B. The next
demo is partly measuring discovery tax; every extra paging idiom is another
surface the model has to relearn.

Example model-facing API, whether implemented as a prelude or upstream:

```clojure
(evidence/run-summary "edit-2026-07-03")
(evidence/stage-bundle {:run_id "edit-2026-07-03" :stage "analyst"})
(fixture/read "reconcile-totals-before")
```

This can reuse the existing `log/` substrate, but it should not expose raw log
search as the primary experiment interface. Raw logs are for debugging;
evidence bundles are curated inputs for a pre-registered run.

Recommended implementation outline:

1. Add a library-side evidence projection module, not an MCP-only special case.
   Suggested module:

   ```elixir
   PtcRunner.Evidence
   PtcRunner.Evidence.Bundle
   PtcRunner.Evidence.Holder
   ```

   `PtcRunner.Evidence.tools/2` should mirror
   `PtcRunner.TraceLog.Introspection.tools/2`: build host-bound closures over a
   holder process so large logs/files stay outside the sandbox and only bounded
   result pages enter PTC-Lisp memory. The implementation should accept either
   a pre-parsed bundle spec or a path to a JSON manifest. Path manifests should
   resolve file paths relative to the manifest directory; absolute item paths
   are out of scope for Slice B.

2. Define a versioned operator bundle manifest. Keep it deliberately dumb and
   data-shaped; do not add benchmark logic.

   ```json
   {
     "schema_version": 1,
     "bundle_id": "edit-2026-07-03/analyst",
     "description": "Evidence for analyst stage",
     "max_item_bytes": 65536,
     "items": [
       {
         "id": "run-summary",
         "kind": "markdown",
         "path": "run-summary.md",
         "model_visible": true
       },
       {
         "id": "stage4-counters",
         "kind": "log_counters",
         "log_source": "turn-logs",
         "filters": {"tags": {"run": "edit-2026-07-03", "stage": "editor"}},
         "model_visible": true
       },
       {
         "id": "expected-layer",
         "kind": "answer_key",
         "path": "answer-key.json",
         "model_visible": false
       }
     ]
   }
   ```

   Supported Slice B item kinds should be small:

   - `text` / `markdown` / `json`: read a fixture file, bound bytes, return
     string-keyed metadata plus content;
   - `log_counters`: run the existing trace-log counter projection with the
     declared filters;
   - `log_turns`: return selected turn fields, not full raw events;
   - `prelude_export`: optional manifest item for static prelude surface
     snapshots captured by Slice A export.

   `answer_key` or `operator_only` items may be present for harness checks and
   manifest hashing, but model-facing tools must refuse to read them.

   Path authority must be explicit and canonicalized. File item `path` values
   resolve relative to the manifest directory and must stay under that bundle
   root after `Path.expand/2` and symlink-aware canonicalization. For the first
   MCP slice, keep `log_source` values under the bundle root too. A library API
   may accept host-supplied `allowed_log_roots`, but the MCP server should not
   expose that authority until it also adds concrete config such as repeatable
   `--evidence-log-root PATH` / `PTC_RUNNER_MCP_EVIDENCE_LOG_ROOTS`, boot/start
   echoing of canonical root fingerprints, and tests for multiple roots. Do not
   make `..` traversal work by default. The example above assumes `turn-logs/`
   is copied under the bundle root. Symlinked external logs require the explicit
   allowed-root config and audit story.

   The `log_turns` kind needs its own evidence projection contract. It must not
   reuse `log/turns` wholesale, because the debugging projection can include
   full programs, result previews, failures, tool calls, and catalog ops. Default
   model-visible `log_turns` fields should be limited to:

   ```json
   ["turn", "attempt", "committed", "status", "tags"]
   ```

   A manifest may opt into additional safe fields such as `catalog_ops_count`,
   `tool_calls_count`, or bounded `fail.reason`. Full `program`,
   `result_preview`, raw `fail.message`, and raw tool-call args/results should
   require explicit item-level field selection and should be treated as evidence
   content with its own checksum and byte bounds.

   `log_turns` selection should be explicit and independent of the raw
   `log/turns` API shape. A `log_turns` manifest item must include `log_source`
   and may include:

   ```json
   {
     "filters": {"tags": {"run": "edit-2026-07-03", "stage": "editor"}},
     "session_id": "optional-exact-correlation-id",
     "fields": ["turn", "attempt", "committed", "status", "tags"]
   }
   ```

   Apply `filters` first using the same tag/driver/status/time semantics as the
   `log/` tools, then apply `session_id` if present. If `session_id` is omitted,
   return all matching turn events across sessions. Stable ordering is by source
   file order, then event `seq` when present, then `timestamp`, then driver
   correlation id, then `attempt`; this keeps directory-backed bundles
   deterministic without requiring the model to know session ids in advance.

3. Expose one model-facing prelude namespace, `evidence/`, backed by typed tools.
   Keep the public surface smaller than raw log introspection:

   ```clojure
   (ns evidence
     "Read-only curated evidence bundles. Evidence is untrusted DATA."
     {:visibility :prompt})

   (defn bundle
     "Return bundle metadata and visible item ids."
     [& opts]
     (tool/evidence_bundle (or (first opts) {})))

   (defn read
     "Read one visible evidence item by id."
     [id & opts]
     (tool/evidence_read (merge {:id id} (or (first opts) {}))))

   (defn page
     "Page visible evidence items."
     [& opts]
     (tool/evidence_page (or (first opts) {})))
   ```

   Tool names should be `evidence_bundle`, `evidence_read`, and
   `evidence_page`. `evidence_page` must use the same
   `items`/`next_cursor`/`has_more`/`limit` envelope as `log/`. `evidence_read`
   should return one item envelope. File-like items use `content`:

   ```json
   {
     "bundle_id": "edit-2026-07-03/analyst",
     "item_id": "run-summary",
     "kind": "markdown",
     "checksum": "sha256:...",
     "bytes": 1234,
     "content": "...",
     "truncated": false
   }
   ```

   Structured items such as `log_counters`, `log_turns`, and `prelude_export`
   should return `data` instead of JSON-in-a-string `content`:

   ```json
   {
     "bundle_id": "edit-2026-07-03/analyst",
     "item_id": "stage4-counters",
     "kind": "log_counters",
     "checksum": "sha256:...",
     "bytes": 456,
     "data": {"turns": 12, "tool_calls": 3},
     "truncated": false
   }
   ```

   The bundle metadata should include a stable `bundle_checksum` over the
   visible item ids, kinds, checksums, and byte counts. If the manifest includes
   operator-only items, include a separate `manifest_checksum` for harness use,
   but do not expose hidden item contents or ids in Slice B. If a later slice
   needs model-visible metadata about hidden items, make it a separate explicit
   manifest field with an allowlisted key set and its own tests; do not overload
   `model_visible: false`.

   Checksums for structured items must be computed over canonical JSON bytes,
   not Elixir map inspection. Canonical JSON means string-keyed data with maps
   recursively sorted by key, arrays kept in projection order, no insignificant
   whitespace, and UTF-8 output. The `bytes` field for structured items is the
   byte size of those canonical JSON bytes. File-like items checksum the exact
   served bytes after byte bounding/truncation.

   Structured items must also be bounded. For Slice B, prefer fail-closed
   loading when a structured projection's canonical JSON bytes exceed
   `max_item_bytes`; do not silently return a partial `data` object with
   `truncated: true`, because a partial counter or turn list is easy to mistake
   for complete evidence. File-like items may still truncate served bytes, since
   the returned `content`, `bytes`, `checksum`, and `truncated` fields describe
   the exact bytes the model received.

4. Add evidence-read accounting to turn logs without making evidence a new
   mutable side effect. This requires explicit plumbing; `TurnEvent.build/1`
   currently only preserves whitelisted fields, and normal tool-call summaries
   are not enough because they intentionally avoid carrying raw tool results.
   Implement one of these two concrete paths:

   - Preferred: add a small per-eval side ledger owned by the session runner.
     Evidence tool closures append safe read records to that ledger, session
     commit passes `evidence_reads:` into `TurnEvent.build/1`, and
     `TurnEvent.build_data/1` normalizes/preserves only the safe fields.
   - Smaller fallback: teach `TurnEvent.tool_call_summary/1` to preserve a
     safe evidence-read projection for calls to `evidence_read` /
     `evidence_page`, and derive `evidence_reads` from those summaries.

   Safe evidence-read records should have this shape:

   ```json
   {
     "bundle_id": "edit-2026-07-03/analyst",
     "item_id": "run-summary",
     "source_ref": "run-summary.md",
     "checksum": "sha256:...",
     "bytes": 1234,
     "truncated": false
   }
   ```

   `source_ref` is an audit label, not a filesystem disclosure. For file items,
   use the manifest-relative path string after manifest normalization; for
   log-derived items, use the manifest `log_source` plus the item id or query
   kind. Never record absolute canonical paths in model-visible results or turn
   events. `evidence_page` item summaries should include the same safe audit
   keys as reads, including `bundle_id`, `item_id`, `source_ref`, `checksum`,
   `bytes`, and `truncated`, so a paged evidence read can be audited without
   fetching every item body.

   If full session plumbing is too broad for the first patch, land the
   library-side evidence tool return fields first and make the MCP/session
   logging hook Slice B.2 before using evidence bundles in a benchmark gate. Do
   not defer bundle checksums: they are the audit primitive that lets a gate
   verify exactly what a model could see.

5. Integrate with MCP by configuration, not by exposing a filesystem browser.
   Suggested first CLI/env shape:

   ```text
   --evidence-bundle PATH
   PTC_RUNNER_MCP_EVIDENCE_BUNDLE=PATH
   ```

   For Slice B, choose the simple current-model-compatible grant: a server
   process configured with `--evidence-bundle` grants the evidence prelude/tools
   to every MCP session on that server. The bench launcher gets stage scoping by
   starting separate stage-specific server processes with different evidence
   bundle manifests, or with no evidence bundle for stages that should not read
   evidence. Do not imply per-session evidence grants until Slice C adds role or
   grant state to `lisp_session_start` / session registry metadata. The server
   should not infer benchmark stages from tags.

   MCP wiring must compose with the existing prelude/tool plumbing rather than
   replacing it:

   - append the `evidence/` prelude source to any already configured runtime
     prelude source for stateless `lisp_eval`, stateful `lisp_session_eval`,
     and SubAgent-backed `lisp_task`;
   - merge evidence tool closures into the per-eval tool map alongside upstream,
     prelude-store, and configured host tools; `lisp_task` must receive those
     tools too, otherwise the configured runtime prelude exposes an impossible
     namespace that fails every task before planning can complete;
   - fail closed during server boot or session/eval setup if the evidence
     namespace, prelude symbols, or tool names collide with already configured
     surfaces;
   - keep evidence *access* identical for stateless and stateful MCP paths, so a
     benchmark cannot accidentally test one evidence surface and deploy another.

   Statefully selected data preludes need a narrower composition rule. When the
   only configured runtime prelude is the official `evidence/` prelude, treat it
   as a host prefix/component, not as a mutually exclusive `runtime_prelude`, so
   this works:

   ```json
   {"preludes": ["paged_base@1"]}
   ```

   while the server is configured with `--evidence-bundle`.

   Do not extend that exception to operator preludes. If the server is configured
   with both `--prelude` and `--evidence-bundle`, the composed runtime prelude
   still counts as an operator-configured prelude and remains mutually exclusive
   with selected store preludes. Otherwise, enabling evidence would make an
   operator helper silently inherit `prelude_store_*` backing tools through the
   store-read prefix. The implementation should distinguish evidence-only from
   operator-plus-evidence explicitly and fail closed with the existing
   `:runtime_prelude/:prelude and :preludes are mutually exclusive` path for the
   latter.

   Turn-log accounting is a separate concern. Existing MCP turn logs are emitted
   by stateful `lisp_session_eval`; stateless `lisp_eval` does not currently
   emit `TurnEvent` records. For Slice B, require `evidence_reads` stamping on
   stateful session turns and SubAgent turns (`lisp_task` uses SubAgent under
   the hood). If the evidence prelude is also granted to stateless `lisp_eval`
   for API symmetry or smoke tests, document it as non-evidence-grade access:
   the response is bounded and checksummed, but the read is not turn-log
   auditable. Evidence-grade launchers must use stateful sessions or
   SubAgent-backed `lisp_task` until a stateless turn-event/audit design lands.
   Do not claim "what the model could see" auditability for stateless
   `lisp_eval` without that additional design.

   A future alternative is explicit session-start evidence grants:

   ```json
   {"evidence_bundle": "analyst"}
   ```

   That is out of scope for Slice B unless it also adds session state,
   start-response echoing, turn-log stamping, and execution-time enforcement for
   that grant.

6. Keep redaction as operator-supplied selection. In Slice B, "redaction" means
   only:

   - hidden items are not readable by model-facing tools, and public read errors
     for hidden ids are indistinguishable from unknown ids;
   - selected log fields are projected through existing `log/` projections;
   - file items are served exactly as selected, under byte bounds and checksum;
   - malformed manifests or paths outside the bundle root fail closed.

   Do not implement regex redaction or domain-specific scrubbing in this slice.
   If a benchmark needs edited text, the operator should write the edited file
   into the bundle and checksum it.

7. Fix `log/counters` token semantics as part of Slice B or immediately before
   it. Today the counter API can collapse missing token observations into zero.
   Change `sum_field/2`-style aggregation so each token field returns `nil`
   when no turn has an integer value, and add companion counts:

   ```json
   {
     "input_tokens": null,
     "input_tokens_known_count": 0,
     "duration_ms": 1234
   }
   ```

   This preserves the distinction between "MCP server cannot see host LLM
   tokens" and "the run used zero tokens." Existing duration/tool/catalog
   counters should remain numeric.

Suggested implementation order:

1. Fix `log/counters` unknown-token semantics and tests.
2. Add `PtcRunner.Evidence` manifest parsing, holder, paging, checksums, and
   pure tool closures with unit/integration tests.
3. Add `evidence/` prelude source and docs.
4. Wire optional MCP config/CLI grant for evidence bundles.
5. Ensure the MCP grant covers stateless evals, stateful evals, and
   SubAgent-backed `lisp_task`, with selected store preludes composing with the
   evidence prefix.
6. Add turn-log `evidence_reads` stamping if it can be done without broad
   session refactor; otherwise land it as Slice B.2 before using evidence
   bundles in a benchmark gate.

`log/counters` remains the low-level metrics primitive underneath evidence
bundles. For MCP-session cost signals, prefer `duration_ms`, `attempts`,
`tool_calls`, `catalog_ops`, and upstream-call counts; token totals are unknown
unless the turn log contains integer token observations.

Slice B tests:

- evidence bundle reads from stateful MCP sessions are recorded in turn logs
  with bundle id, item id, checksum, safe `source_ref`, and byte counts;
- malformed selection/redaction specs fail closed before serving evidence;
- file paths and log sources cannot escape the bundle root or configured
  allowed log roots, including through symlinks;
- MCP-configured bundles either reject external log roots or require explicit
  `--evidence-log-root`-style config with canonical root fingerprints recorded
  in boot/start evidence;
- hidden/operator-only item ids and content are absent from model-facing
  `bundle` and `page` responses;
- `evidence_read` refuses hidden/operator-only ids with the same public error as
  unknown ids, `bundle_checksum` excludes hidden items, and
  `manifest_checksum` remains harness-only;
- model-visible `log_turns` defaults exclude raw programs, result previews,
  raw failure messages, and raw tool-call args/results;
- `log_turns` supports filter-only and filter-plus-session selection with
  deterministic ordering across directory-backed log sources;
- structured evidence item checksums and byte counts are computed from canonical
  JSON, structured items fail closed when their canonical bytes exceed
  `max_item_bytes`, while file-like items use exact served bytes;
- all paged evidence APIs use `items`/`next_cursor`/`has_more`/`limit`;
- `--evidence-bundle` works through `lisp_eval`, `lisp_session_eval`, and
  `lisp_task`, and selected store preludes still compose with the evidence
  namespace;
- `--prelude` is preserved when `--evidence-bundle` is configured, including in
  stateful sessions; without an evidence bundle, arbitrary configured runtime
  preludes remain incompatible with selected store preludes and do not receive
  prelude-store backing tools implicitly;
- `log/counters` filters by tags before aggregation and preserves unknown token
  semantics instead of collapsing missing token observations to zero;
- a model can compute stage metrics with
  `(log/counters {:tags {"run" "..." "stage" "..."}})` without hand-prepared
  metrics files.

### Slice C — Role-Scoped Session Policy

Goal: introduce a first-class role/grant model without changing credential
storage yet.

Status: core implemented via `--session-roles` /
`PTC_RUNNER_MCP_SESSION_ROLES` (`mcp_server/lib/ptc_runner_mcp/sessions/policy.ex`),
except where a sub-bullet below has its own narrower status note.
[`../future/prelude-selected-capability-namespaces.md`](../future/prelude-selected-capability-namespaces.md)
proposes folding the `mode: "write_capable"` special case into prelude
selection on top of this now-implemented grant model — read that doc against
this slice, not as a standalone redesign.

Implementation boundary:

- this slice is MCP-session scoped, not a full authorization system;
- role selection is self-declared in `lisp_session_start`;
- outer MCP `tools/list` and pre-session `tools/call` remain process-level;
- `lisp_eval` and `lisp_task` remain process-level unless the process-level
  policy says otherwise;
- credentials stay unchanged until Slice D.

Recommended first pass:

- define one policy subject shape for every call path that can expose or invoke
  model-facing capability: outer MCP `tools/list` / `tools/call`, stateless
  `lisp_eval`, stateful `lisp_session_eval`, and SubAgent-backed `lisp_task`;
- add a session `role` field with a configured grant map for stateful sessions;
- keep stateless calls under the process-level outer policy in this slice, and
  document that they are not per-role until Slice D/E;
- keep outer MCP `tools/list` / pre-session `tools/call` under a process-level
  policy in Slice C. MCP discovery happens before `lisp_session_start`, so it
  cannot vary by a self-declared session role. Stage-specific launchers can
  start separate server processes with different outer policies. Role-specific
  discovery starts inside the accepted stateful session unless a later slice
  adds credential-bound role selection before `tools/list`;
- filter pre-session outer MCP discovery by the process-level outer policy, and
  filter in-session discovery by role across host PTC tools, prelude-store
  tools, and selected prelude exports;
- enforce the same grant at execution time, including for tools that are still
  known to the host runtime but hidden from the model-facing catalog;
- echo accepted `role`, normalized `tags`, and grant fingerprint in
  `lisp_session_start` responses;
- record role and grant fingerprint in session start and turn logs;
- keep credential resolution process-wide for this slice, but verify a role
  cannot call ungranted host PTC/prelude-store tools even when the host runtime
  knows they exist.

Concrete config:

Add a file/env flag pair:

```text
--session-roles PATH
PTC_RUNNER_MCP_SESSION_ROLES=PATH
```

The file is JSON. Keep it deliberately small and process-wide:

```json
{
  "default_role": "analyst",
  "outer_policy": {
    "mcp_tools": [
      "lisp_session_start",
      "lisp_session_eval",
      "lisp_session_list",
      "lisp_session_list_preludes",
      "lisp_session_inspect",
      "lisp_session_forget",
      "lisp_session_close"
    ]
  },
  "roles": {
    "analyst": {
      "ptc_tools": ["evidence_bundle", "evidence_read", "evidence_page"],
      "upstream_tools": [],
      "prelude_store": "read",
      "preludes": ["paged_base@1", "paged_audit@1"],
      "modes": ["read_only"]
    },
    "editor": {
      "ptc_tools": ["evidence_bundle", "evidence_read", "evidence_page"],
      "upstream_tools": [],
      "prelude_store": "write",
      "preludes": ["paged_base@1", "paged_audit@1"],
      "modes": ["read_only", "write_capable"]
    }
  }
}
```

Absence of `--session-roles` preserves current behavior: every session starts
with `role: nil`, `grant_fingerprint: nil`, and the effective grant is
unrestricted except for existing feature flags such as
`--sessions-allow-prelude-write`.

When the config is present, `lisp_session_start` accepts:

```json
{"role": "analyst", "tags": {"run": "demo-07", "stage": "analyst"}}
```

If `role` is omitted, use `default_role` when configured. Reject unknown roles,
empty/non-string role values, and role names that are not bounded ASCII ids
(`A-Za-z0-9_.-`, 1-64 bytes). Normalize grants once at boot and compute a
stable `grant_fingerprint` from canonical JSON over the normalized effective
grant, including resolved defaults.

Grant vocabulary:

- `mcp_tools`: outer MCP tools the client may see or call, such as
  `lisp_eval`, `lisp_task`, `lisp_session_start`, and `lisp_session_eval`.
  In Slice C this is a process-level outer policy until there is a
  credential-bound role source before `tools/list`;
- `ptc_tools`: host-bound PTC-Lisp tools injected into the sandbox, such as
  `evidence_read` or prelude-store backing tools. Slice C also prunes attached
  prelude exports whose declared or collected host-tool refs are not granted, so
  `ns-publics` and start-response discovery do not advertise denied host-tool
  wrappers. The filtered prelude must also prune `source_index`; otherwise a
  denied wrapper can still leak through `(source ns/name)` when the model knows
  or guesses the ref. Preserve source entries for retained public exports and
  their transitive private helpers, but do not preserve denied public export
  source. Injection remains the authority boundary: this filter can remove
  tools from an injected set, but it never grants a tool that session mode,
  prelude-store level, evidence-bundle setup, or host configuration did not
  inject. Explicit evidence-backed allowlists must include
  `evidence_bundle`, `evidence_read`, and `evidence_page`.

  Status: enforced by a config-install-time diagnostic (not a session-start
  error). When an evidence bundle is configured and a role's `ptc_tools`
  allowlist has zero overlap with the three evidence tool names,
  `Sessions.Config.set/1` logs a `role_evidence_tools_unreachable` warning
  (role, grant fingerprint, evidence tool names) once per config install.
  Partial evidence grants (some but not all three tools) are not flagged —
  that is a deliberate, tested scoping pattern, not a misconfiguration. This
  is a warning, not a hard error, because `evidence_bundle` is a
  process-global setting: a role with zero evidence access on a multi-role
  server is a legitimate least-privilege config, not necessarily a mistake;
- `upstream_tools`: `[]` denies all upstream operations for the configured role,
  `"all"` grants the role every configured upstream operation, and an array of
  canonical `upstream:<server>/<tool>` ids grants only those operations.
  Materialized projected catalogs are filtered to the same set. Lazy catalogs do
  not weaken enforcement because prelude attach checks explicit grants and
  `(tool/call ...)` dispatch denies ungranted resolved operations before
  upstream dispatch;
- `prelude_store`: none/read/write authority for the built-in `prelude/`
  namespace and backing tools;
- `preludes`: exact selected prelude refs the role may request, normalized to
  `id@version` or `{id, version, checksum}`. Bare ids are not a role-policy
  grant because they allow silent version drift. Object grants must reject
  unknown keys, so a typo such as `checksumm` cannot silently become an
  unchecksummed `{id, version}` grant;
- `modes`: accepted built-in session modes.

Transitive dependency policy: a granted exact ref may bring in its pinned
dependency closure through `PreludeStore.Selection`. Those dependency exports
are visible at runtime because they are part of the frozen compiled bundle, but
they are not directly requestable by the role unless their own exact refs are
also listed. Start responses and turn events must record the resolved closure
so gates can see which dependency versions actually attached.

Suggested normalized internal shape:

```elixir
%PtcRunnerMcp.Sessions.Policy{
  default_role: "analyst" | nil,
  outer_policy: %OuterPolicy{mcp_tools: MapSet.t(String.t())},
  roles: %{"analyst" => %Grant{}}
}

%Grant{
  role: "analyst" | nil,
  ptc_tools: :all | MapSet.t(String.t()),
  upstream_tools: :all | MapSet.t(String.t()),
  prelude_store: :none | :read | :write,
  preludes: :all | %{{String.t(), pos_integer()} => %{id: String.t(), version: pos_integer(), checksum: String.t() | nil}},
  modes: MapSet.t([:read_only | :write_capable]),
  fingerprint: "sha256:..."
}
```

Avoid atoms from untrusted JSON role/tool names. The struct may store binaries
and existing closed-set atoms only. Parse the JSON schema strictly at every
level: top-level config, `outer_policy`, each role grant, and each prelude grant
object all reject unknown keys.

`mode` remains narrower than `role`: `mode: "write_capable"` controls the
built-in session capability class, while `role` controls the full model-facing
grant. `mode` must not be the only enforcement point for write-capable
prelude-store tools; the effective grant is the intersection of role policy,
mode, server feature flags, and selected preludes.

Enforcement points:

1. `PtcRunnerMcp.Application.parse_args/1` and
   `PtcRunnerMcp.Sessions.Config.resolve/1` load `--session-roles` and store a
   normalized policy in `Sessions.Config`.
2. `lisp_session_start` validates the requested `role` before resolving
   preludes or compiling capabilities. It rejects a requested `mode` not listed
   in the role grant.
3. Requested `preludes` are checked against `grant.preludes` before
   `PreludeStore.Selection.resolve_with_prefix!/4`. Match exact normalized
   refs, not just ids, so granting `base@1` does not allow `base@3`.
4. Read-only prelude introspection is available only when
   `grant.prelude_store in [:read, :write]`; write-capable sessions require
   `grant.prelude_store == :write` in addition to the existing
   `--sessions-allow-prelude-write` and configured-store checks.
5. `Session.lisp_opts/3` filters the final host PTC tool map through
   `grant.ptc_tools` before passing it to `PtcRunner.Lisp.run/2`, and filters
   the attached compiled prelude to exports whose `tool:` requirements /
   collected host-tool refs and `upstream:` requirements are granted. Execution
   therefore fails closed even if a hidden tool exists in the host runtime,
   without breaking unrelated exports in the same prelude. The same filtered
   prelude must be used for discovery, evaluation, and live-session projection;
   filter both `exports` and `source_index` so `doc`, `meta`, `ns-publics`,
   `apropos`, and `source` have the same role-shaped view. Use the compiled
   `form_graph` rather than parsing rendered source hints when retaining private
   helper source for allowed exports.
6. `Sessions.projected_root_runtime/1` projects both credential grants and
   upstream operation grants. Discovery sees the projected catalog, prelude
   attach receives the explicit upstream grant set, and `tool/call` checks the
   same projected authority at dispatch time.
7. Add top-level `role` and `grant_fingerprint` fields to
   `PtcRunner.TraceLog.TurnEvent`. `Session.emit_turn_event/8` fills them from
   session state; `PtcRunner.TraceLog.Introspection` projects them from grouped
   turn events in `log/sessions` and individual turns in `log/turns`. The full
   grant is not written to turn logs.
8. Start responses and live session summaries include `role` and
   `grant_fingerprint`. Turn logs remain turn logs: a session that starts and
   never evaluates has no `turn` event and therefore will not appear in
   `log/sessions`. Demo gate runners that audit roles from turn logs must require
   at least one accepted eval attempt for every stage session, or use the live
   session list/admin surface while the session still exists.

Interim trust model: until Slice D binds roles to credentials/tokens, the role
is self-declared at session start. That is acceptable for bench harnesses, not
for production authorization. The gate runner must therefore verify after the
run that each session's recorded role equals the expected stage role and that
the grant fingerprint equals the expected configured grant.

Example gate check:

```clojure
(log/sessions {:tags {"run" "demo-07" "stage" "editor"}})
(log/counters {:tags {"run" "demo-07" "stage" "editor"}})
```

Every returned session for `stage=editor` must have `role="editor"` and the
expected grant fingerprint. A mismatch is a gate failure, even if the model's
final answer was correct.

Slice C tests:

- outer `tools/list` uses the configured process-level policy and does not try
  to infer a session role before `lisp_session_start`;
- `lisp_session_start` rejects unknown roles and malformed role values;
- accepted role/tags/grant fingerprint are echoed in start response;
- turn events include role, tags, and grant fingerprint;
- process-level `outer_policy.mcp_tools` filters outer `tools/list` /
  `tools/call`; role-scoped in-session discovery covers granted host PTC
  wrappers, prelude-store forms, and selected prelude exports, not MCP
  `tools/list`;
- prelude role grants are exact refs: granting `base@1` does not allow
  `base@2`, while pinned transitive dependencies attach and are recorded in the
  resolved closure;
- execution rejects an ungranted tool even if the host runtime can call it;
- stateless `lisp_eval` and `lisp_task` have an explicit policy subject, or are
  clearly kept under process-level policy until role-scoped stateless calls are
  designed;
- `mode: "write_capable"` remains insufficient to grant unrelated upstream
  tools or prelude-store write tools that the role does not grant;
- `upstream_tools` grants may name explicit upstream operations or `"all"`; the
  server enforces them in catalogs, prelude attach/filtering, and dispatch.

### Slice D — Role-Scoped Credentials

Goal: bind credentials to roles after role-level tool enforcement exists.

This should be implemented as independent sub-slices. D1 and the D2a session
projection path are implemented, including the MCP-session regression test for
credentialed MCP HTTP denial/no-root-client reuse. D3 is the production
hardening step that turns the same mechanism into bearer-token authority rather
than harness discipline.

#### D1 — Credential Grants In Session Roles

Status: implemented.

Extend the existing `--session-roles` policy file instead of adding a second
role config. The policy is already the server's authority object for modes,
host PTC tools, preludes, and prelude-store access; credential grants should
live in the same grant fingerprint so the bench runner can audit one value.

Proposed shape:

```json
{
  "default_role": "analyst",
  "outer_policy": {
    "mcp_tools": ["lisp_session_start", "lisp_session_eval", "lisp_session_inspect"]
  },
  "roles": {
    "analyst": {
      "modes": ["read_only"],
      "ptc_tools": [
        "evidence_bundle",
        "evidence_read",
        "evidence_page",
        "log_list",
        "log_read"
      ],
      "prelude_store": "read",
      "preludes": [{"id": "paged_base", "version": 1}],
      "credentials": []
    },
    "editor": {
      "modes": ["write_capable"],
      "ptc_tools": ["prelude_store_write"],
      "prelude_store": "write",
      "preludes": [],
      "credentials": ["github_writer"]
    }
  }
}
```

`credentials` entries are upstream credential binding names from the root
upstreams config, not secret values and not env var names. `:all` is allowed
only for test/operator roles; normal demo roles should use an explicit list.
Absent `credentials` should mean `[]`, not `:all`, so adding this field does
not silently grant existing roles process-wide upstream authority.

Policy parser work:

- add `credentials` to `roles.<role>` allowed keys;
- normalize to `MapSet.t()` or `:all` on `%Policy.Grant{}`;
- include a fingerprint schema version and the sorted credential grant list in
  `grant.fingerprint`. Gate checks should compare the fingerprint together with
  the server commit/build stamp when runs may span upgrades;
- expose a helper such as `credential_allowed?/2` and `credential_grants/1`;
- keep the full grant out of turn logs and responses; only role and grant
  fingerprint are model-facing.

Validation work:

- when the root upstream runtime is configured, reject role policies that grant
  unknown credential binding names. Current implementation does this as lazy
  fail-closed validation during `lisp_session_start`, after the root runtime is
  available; this is acceptable for the demo and keeps root runtime loading
  order simple. A later startup preflight may turn the same check into an
  earlier operator error, but it is not required for Slice D;
- upstream operation grants and credential grants are independent: Slice E
  controls which `server/tool` operations a role may see and call, while Slice D
  controls which credentials those allowed calls may use;
- role credentials do not grant local host PTC tools and do not bypass mode or
  prelude-store grants.

#### D2 — Runtime Credential Projection

Status: D2a implemented for stateful MCP sessions and OpenAPI upstream calls;
D2b projection-scoped MCP HTTP clients remain open.

Add a role-shaped upstream runtime projection instead of teaching every caller
to inspect credential grants. The invariant should be:

> Every upstream discovery result and upstream call for a session is evaluated
> against a runtime view whose credential set is exactly the active role's
> credential grant set.

Current seam:

- MCP sessions build a root `RunContext` in `Sessions.root_aggregator_run_opts/1`;
- stateless `lisp_eval` / `lisp_task` build a root `RunContext` in
  `Tools.execute_with_root_runtime/4`;
- both paths call `Eval.run_context(RootUpstreamRuntime.runtime(), ...)`;
- `PtcRunner.Upstream.Runtime` owns parsed upstream config and a
  process-wide `%PtcRunner.Upstream.Credentials{}` value;
- OpenAPI and MCP HTTP transports materialize auth through
  `Credentials.headers(config.credentials, auth_emitters)`.

Implementation outline:

1. Add a projection API on `PtcRunner.Upstream.Runtime`, for example
   `Runtime.project(runtime, credential_grants: grants)`. Also expose a
   non-secret `Runtime.credential_binding_names/1` helper for policy startup
   validation.
2. The projection should preserve upstream definitions, tool catalogs, limits,
   and catalog exposure settings, but split **auth credentials** from
   **scrub credentials**. Auth credentials are the role-granted subset used to
   build outgoing headers. Scrub credentials remain the root/global credential
   set so `Runtime.scrub(projected_runtime, value)` still redacts any plaintext
   secret known to the process.
3. Add an explicit subset/project API on `PtcRunner.Upstream.Credentials`, for
   example `Credentials.subset(credentials, grants)`. This must copy only
   already-materialized binding values and metadata into an auth-only credential
   struct; it must not re-read env/files, expose secret values, or mutate the
   global redaction set. Unknown grant names fail during policy/runtime
   validation. Missing emitter bindings in a projected credential set fail
   locally before network I/O.
4. If an upstream auth emitter references a binding outside the projection,
   discovery may still show the upstream/tool for D2, but execution must fail
   closed with a scrubbed `:upstream_unavailable` / `:auth_unavailable`-style
   error before any network call is attempted. Do not fall back to the root
   credentials.
5. Use the projected runtime when constructing a session `RunContext`. The
   session's grant is already available in start opts and session state.
6. Leave stateless `lisp_eval` and `lisp_task` on the unrestricted root runtime
   unless/until they accept an explicit policy subject. If this slice adds a
   `role` argument to those stateless tools, it must use the same
   `Policy.resolve_grant/2` path and the same runtime projection as sessions;
   otherwise the docs and tests should state that Slice D is session-scoped.
7. Keep direct root/operator APIs unrestricted unless they explicitly carry a
   role grant. The role boundary is for MCP session/user execution, not for
   internal admin code.

The projection can be a lightweight wrapper for pure/local transports only if
the call path actually consumes the projected config. Be careful with current
MCP HTTP and MCP stdio clients: once a transport client is started, it owns
state such as `config.credentials` and, for MCP HTTP, `session_id`. Passing a
projected upstream map that still contains a root `client_pid` would reuse the
root client's credentials and violate the slice. D2 must choose one of these
explicit designs:

- add per-call/per-list auth override support in the transport client and prove
  the upstream protocol does not bind session state to the original auth
  subject; or
- maintain projection-scoped transport clients keyed by
  `{upstream_name, credential_grant_fingerprint}` and never reuse a root client
  for a restricted projection.

Default to projection-scoped clients for MCP HTTP/stdio unless the per-call
override invariant is proven in tests. OpenAPI can use a lightweight projected
config because it builds request headers for each call and does not keep a
long-lived authenticated session in the runtime process.

Minimum D2a behavior may deliberately avoid projection-scoped MCP clients if it
fails closed before network I/O whenever a projected role lacks one of an MCP
HTTP upstream's auth bindings. In that implementation:

- OpenAPI uses lightweight projected configs and is fully callable with granted
  credentials;
- MCP stdio is passed through unchanged because it has no upstream credential
  binding path today;
- unauthenticated MCP HTTP can reuse the root client, because there is no
  credential authority to partition;
- credentialed MCP HTTP may reuse the root client only when every auth binding
  required by that upstream is included in the projection;
- credentialed MCP HTTP with a missing grant must strip any root `client_pid`,
  use projected credentials for discovery and validation paths, and fail
  locally before `initialize`, `tools/list`, or `tools/call` can leave the
  process.

Projection-scoped MCP HTTP clients remain D2b and are required before a
restricted role can call a credentialed MCP HTTP upstream with a non-root
credential subset.

The D2a MCP-session regression coverage now includes credentialed MCP HTTP
denial/no-root-client reuse. The session-level test configures a credentialed
MCP HTTP upstream, starts a role with `credentials: []`, calls it through
`lisp_session_eval`, and verifies:

- the result is a generic credential-unavailable upstream failure;
- no credential binding id or plaintext secret appears in the model-facing
  envelope;
- the fixture server observes no request, proving the session path stripped the
  root-authenticated client and failed before network I/O.

Projection-scoped client lifecycle:

- the root `Runtime` process owns the projection-client cache in its GenServer
  state; projected runtime handles are lightweight references into that owner,
  not independent owners of OS processes;
- cache keys include upstream name, transport, auth credential grant
  fingerprint, and any upstream config fingerprint that affects client state;
- clients are reference-counted or TTL-cleaned when no live session/run context
  can still use them. A simpler first implementation may close projection
  clients at the end of each session, but it must not leak long-lived OS ports
  or HTTP sessions;
- `Runtime.terminate/2` stops both root clients and projection clients;
- when building a projected upstream map, strip any root `client_pid` before
  starting/looking up a projection client. Tests must cover that a restricted
  projection cannot call through a root-authenticated client.

Expected runtime behavior:

- `Runtime.scrub(projected_runtime, value)` still uses the global credential
  redaction set. Global scrubbing is allowed and preferred as
  defense-in-depth;
- model-facing payloads never include credential binding ids. Error text should
  say the upstream is not authorized for the role or that required auth is not
  available, without naming the missing binding;
- operator diagnostics may include binding ids only on non-model paths and only
  after plaintext redaction has run;
- discovery filtering by upstream tool remains Slice E. D2 may leave a visible
  upstream tool that is uncallable because its credential is not granted, but
  the error must be deterministic, local, and pre-network.

#### D3 — Bearer Tokens Bind To Roles

Status: implemented in `mcp_server` as the first HTTP role-credential slice.
The shipped shape uses a separate internal `AuthClaims` struct rather than
extending the public owner map, so downstream PTC session ownership and cleanup
continue to use `PtcOwner.http(mcp_session_id)`.

Slice C's interim trust model lets the model/harness self-declare `role` at
`lisp_session_start`. D3 makes that role server-authenticated for HTTP by
binding bearer credentials to allowed roles.

Keep this intentionally small and forward-compatible:

- retain the existing single `--http-auth-token` behavior as the unrestricted
  legacy/operator mode when no role-token file is configured;
- add an optional `--http-role-tokens` / `PTC_RUNNER_MCP_HTTP_ROLE_TOKENS`
  JSON file whose entries define bearer tokens by non-secret id and allowed
  roles;
- treat `--http-auth-token` and `--http-role-tokens` as mutually exclusive for
  the model-facing MCP surface. The single-token path stays the unrestricted
  compatibility mode; the role-token file is the policy-bound mode. Admin token
  auth remains separate and may coexist with either mode;
- never log plaintext tokens; register all token values in the existing
  redaction set at boot;
- authentication should return the normal HTTP owner plus internal auth claims
  containing an auth subject fingerprint and `allowed_roles`;
- `lisp_session_start` must reject a requested role that is not in the
  authenticated subject's allowed role set;
- when a token allows exactly one role, omitting `role` should select that role;
  when it allows multiple roles and no policy default exists, the client must
  choose one explicitly;
- stdio may stay self-declared/operator-trusted for this slice, but the docs
  and tests must say so.

Proposed file shape:

```json
{
  "tokens": [
    {
      "id": "bench-analyst",
      "token_env": "PTC_BENCH_ANALYST_TOKEN",
      "roles": ["analyst"]
    },
    {
      "id": "bench-editor",
      "token_file": "/run/secrets/ptc_editor_token",
      "roles": ["editor"]
    }
  ]
}
```

`token_env`, `token_file`, and `token_literal` mirror the existing credential
source style. Literal tokens are acceptable for tests only; production examples
should use env/file. The token `id` is non-secret operator metadata and may be
used in diagnostics after hashing, but should not be echoed to models.

Parsing and validation:

- add `PtcRunnerMcp.Http.RoleTokens` as the narrow loader for this file. It
  should read JSON from the configured path and return a map keyed by a token
  hash, not by plaintext token;
- file root shape is exactly `%{"tokens" => [...]}`. Reject unknown root keys
  and unknown entry keys so typos do not silently disable policy;
- each entry requires `id`, one token source (`token_env`, `token_file`, or
  `token_literal`), and non-empty `roles`;
- `id` follows the same bounded role-name style (`[A-Za-z0-9_.-]{1,64}`) and
  must be unique. Role names should be validated against the same role parser as
  the session policy;
- materialized token values must be at least `Http.Config.token_min_bytes()`,
  non-empty after trimming file values, unique by value/hash, and different from
  the admin token when one is configured;
- `token_env` reads a non-empty env var, `token_file` reads a UTF-8/plaintext
  file and trims trailing whitespace, and `token_literal` exists for tests only.
  Do not persist plaintext values in the resolved HTTP config;
- when a role-token file is configured, `Http.Config.resolve/1` should fail if
  HTTP auth is disabled, if `--http-auth-token` is also supplied, or if any role
  token is invalid. For non-loopback binds, the role-token file satisfies the
  same "auth required" condition as the existing single token.

HTTP auth threading detail:

- extend `PtcRunnerMcp.Http.Auth.authenticate/2` so the returned owner carries
  an internal `AuthClaims` struct when a role-token file is active;
- store the authenticated owner on the HTTP session process at creation time,
  as it is today, and include the same claims in the internal request context
  passed through `Http.Session.dispatch/3`;
- when HTTP dispatch injects the internal `owner` argument for session tools,
  also inject non-secret auth claims through an atom-keyed internal
  `:auth_claims` argument after dropping any caller-supplied `"auth_claims"` or
  `:auth_claims`;
- do not extend `Sessions.Owner` normalization with role authority. The
  internal `:auth_claims` field is the authority path. Public string-keyed
  `"auth_claims"` / `"allowed_roles"` fields are rejected or ignored and cannot
  widen role authority;
- run the allowed-role check in `Sessions.prepare_start_opts/1` immediately
  around `Policy.resolve_grant/2`: choose/resolve the requested role, then
  reject it if authenticated HTTP claims exist and the role is not allowed. For
  single-role tokens, the authenticated role may become the default when the
  client omits `role`; for multi-role tokens, require an explicit role unless
  the configured policy default is also in the allowed set.

Concrete minimal implementation:

1. `Http.Config.resolve/1` accepts `:http_role_tokens` and env
   `PTC_RUNNER_MCP_HTTP_ROLE_TOKENS`, validates the file, and stores only a
   resolved role-token index such as `%{role_tokens: %{hash => subject}}`.
   `subject` contains `id`, short `auth_subject_hash`, and sorted
   `allowed_roles`; it does not contain the token value.
2. `Http.Auth.authenticate/2` branches before the single-token branch when
   `cfg.role_tokens` is non-empty: parse `Authorization: Bearer <token>`, hash
   it, look up the subject, and return the current owner shape plus internal
   `auth_claims`. Missing/invalid challenges remain identical to existing
   bearer auth.
3. Add the new CLI option to the strict `Application.parse_args/1` switch table
   and update the HTTP option tables in `docs/mcp-server-configuration.md` and
   `docs/mcp-server-http-deployment.md`. Do not ship an env-only feature while
   documenting a CLI flag.
4. Avoid extending the public `"owner"` argument shape with forgeable role
   claims. Prefer a separate internal owner/auth-claims path:
   - `Http.Session` stores the authenticated owner from HTTP auth;
   - when dispatching session tools, it continues to overwrite any model-supplied
     `"owner"` argument, but it also passes non-secret auth claims through an
     internal atom-keyed field or direct call option that normal JSON clients
     cannot supply;
   - `Sessions.owner_context/1` must not accept string-keyed `"allowed_roles"` or
     `"auth_subject_hash"` from public request JSON as authority;
   - stdio owners do not carry HTTP role claims.
5. `Sessions.start_session/2` passes trusted auth claims into
   `prepare_start_opts/1`. That helper derives the effective role in this
   order:
   - explicit `role` argument, if present;
   - policy default role, if present and allowed by the token;
   - the sole allowed role when HTTP role claims contain exactly one role.
   If no role can be derived, return a deterministic `session_args_error`.
6. The role-allow check happens after `Policy.resolve_grant/2` so unknown roles
   still use the existing policy error. If an HTTP role token is present and the
   resolved role is not in its allowed set, reject with
   `"role is not allowed for this HTTP credential"` or equivalent generic text
   that does not name other allowed roles.
7. HTTP session cleanup keeps closing downstream PTC sessions with
   `PtcOwner.http(mcp_session_id)` because D3 does not change the downstream PTC
   owner shape. Tests should continue to prove registry termination closes
   downstream sessions when the authenticated HTTP session used role-token
   claims.
8. Registry ownership and telemetry continue to use non-secret owner hashes.
   Plaintext tokens never enter logs or owner maps.

Tests:

- config accepts a valid role-token file from CLI/env and rejects malformed
  roots, unknown keys, duplicate ids, duplicate token values, short tokens,
  missing env/file sources, multiple token sources, empty roles, bad role names,
  coexistence with `--http-auth-token`, and equality with `--http-admin-token`;
- `Http.Auth.authenticate/2` accepts a role token, rejects an invalid token with
  the existing challenge, and returns non-secret `allowed_roles` plus stable
  auth subject hashes;
- HTTP `lisp_session_start` with an analyst token can start `analyst` and cannot
  start `editor`;
- a single-role token may omit `role` and gets that role even when no policy
  default is configured;
- a multi-role token without explicit role uses the configured policy default
  only when the default is allowed, otherwise it fails closed;
- model-supplied `"owner"` / `"allowed_roles"` cannot widen authority through
  `tools/call`, direct stdio-style `Tools.call`, or direct `Sessions.start_session`
  inputs;
- deleting an HTTP protocol session and terminating the HTTP session registry
  both close downstream PTC sessions when the authenticated HTTP subject carries
  role-token claims;
- existing single-token HTTP behavior and stdio self-declared roles remain
  unchanged when no role-token file is configured.

Post-ship hardening (review follow-up on the initial D3 commit):

- Plaintext role-token secrets are only needed transiently, to register them
  with the process-wide redaction set at boot. `Http.SessionRegistry.init/1`
  now clears `role_token_redaction_secrets` from its own GenServer state
  immediately after registering, and `Application.start/2` never stores the
  plaintext list into `Application.env` in the first place — the resolved
  `http_config` is scrubbed before `Application.put_env(:ptc_runner_mcp,
  :http_config, ...)`. Nothing outside `Http.Config.resolve/1`'s return value
  (used once, at boot, to register the secrets) sees plaintext role tokens.
- `Application.validate_role_tokens_boot!/1` runs at boot whenever
  `--http-role-tokens` is configured, after both `--session-roles` and
  `--http-role-tokens` have resolved:
  - fails closed if `--sessions` is not also enabled — role grants are only
    enforced for stateful session tools, so without sessions a bound
    credential's `allowed_roles` would never be checked;
  - fails closed if `--session-roles`' `outer_policy.mcp_tools` is left at its
    implicit `:all` default — that default would leave `lisp_eval` /
    `lisp_task` advertised (see below), which do not enforce bearer-bound
    roles. Operators must explicitly enumerate the tools they intend to
    expose (typically the `lisp_session_*` tools);
  - warns (does not fail boot) when a token's `allowed_roles` names a role not
    defined in `--session-roles` — the runtime path already fails closed
    correctly at `lisp_session_start` ("unknown session role"), so this is
    purely an operability signal to catch a typo before first use instead of
    mid-run.
- `lisp_eval` and `lisp_task` never consult a caller's `auth_claims` — role
  grants are enforced only in `Sessions.prepare_start_opts/1`, i.e. only for
  `lisp_session_*` tools. `lisp_eval` is already structurally unreachable
  whenever `--sessions` is enabled (`Tools.call/1` returns `unknown_tool`
  unconditionally), which the boot check above now guarantees is always the
  case in a role-token deployment. `lisp_task` has no such structural gate,
  so `Http.Session`'s dispatch (`maybe_put_http_context`'s call site) now
  denies `tools/call` for either tool up front, before `JsonRpc.dispatch/2`
  is reached, whenever the HTTP owner carries trusted `AuthClaims`. The
  denial is a distinct `role_credential_denied` reason
  (`Envelope.role_credential_denied/1`) rather than the generic
  `unknown_tool`, so it is unambiguous in server logs/audits that this was a
  credential-scope denial and not "tool not registered."

#### Relationship To Existing Credential Systems

There are two credential-related systems today:

- `PtcRunner.Upstream.Credentials` is the root upstream-runtime credential set
  used to build upstream auth headers;
- `PtcRunnerMcp.Credentials` owns MCP-side redaction and HTTP credential
  helpers.

Slice D should extend the upstream-runtime credentials for authority and
continue to feed every materialized secret into MCP redaction. Do not create a
third credential registry. The role policy grants binding names; the runtime
projection decides which of those bindings may be used for outgoing auth in a
session; the redactor remains global so accidental plaintext leaks are scrubbed
even when a value belongs to another role. A projected runtime therefore needs
two credential views internally: `auth_credentials` for authority and
`scrub_credentials` for redaction.

Minimal shape:

- keep credential definitions host-side;
- add role-to-credential grants;
- resolve upstream calls using only the credentials granted to the session role;
- globally scrub plaintext secrets in traces/catalogs, then filter role-facing
  credential/tool metadata to the active role grant set;
- fail closed when a role can see a tool but lacks the credential required to
  call its upstream.

This slice has to reconcile role scoping with the current singleton credential
and redaction design. Today credential bindings and the redaction set are
process-wide, so "active role" needs an explicit projection rule:

- role-facing catalogs, prompts, turn logs, evidence bundles, response
  envelopes, retry feedback, debug payloads, `upstream_calls`, and
  `upstream_results` projections should expose only non-secret grant
  fingerprints, not raw credential binding ids;
- operator logs may retain binding ids only if they are treated as non-model
  diagnostics and still scrub plaintext values globally;
- redaction should remain fail-closed: global plaintext scrubbing is acceptable
  as a defense-in-depth baseline, but role-facing projections must not reveal
  the existence of credentials outside the active role's grant set.
True per-role plaintext redaction would be a separate redactor design task; do
not depend on it for the first role-scoped credential slice.

Conceptual relationship:

```text
credentials = how the host authenticates
upstreams   = external tool providers
role        = which tools and credentials this session may use
mode        = built-in session capability class
preludes    = Lisp-facing libraries over the granted tools
```

This should follow Slice C, not precede it. Credential scoping without tool
filtering still leaves confusing visible-but-uncallable tools; tool filtering
without credential scoping still leaves too much authority available behind the
server boundary.

Slice D tests:

- a role can call an allowed tool only with credentials granted to that role;
- the same upstream/tool fails closed for a role missing the required
  credential;
- plaintext secrets are scrubbed globally, and role-facing catalogs/traces do
  not reveal credential metadata outside the active role grant set;
- credential ids/secrets never appear in model-facing prompts, turn logs,
  evidence bundles, response envelopes, retry feedback, debug payloads,
  `upstream_calls`, or `upstream_results` except as bounded non-secret grant
  fingerprints.

### Slice E — Native Tool-Filter Replacement

Goal: remove the external MCP tool-filter proxy once the server owns both
discovery filtering and execution enforcement.

Status: native operation filtering is implemented for stateful session roles.
Role policies accept `upstream_tools` as `[]`, `"all"`, or explicit
`upstream:<server>/<tool>` ids. Projected runtime catalogs hide denied tools,
prelude filtering/attach fail closed on denied `upstream:` requirements, and
`tool/call` dispatch returns `:upstream_tool_denied` for denied resolved
operations. D2b projection-scoped MCP HTTP clients remain a credential/client
isolation follow-up, not an operation-authorization prerequisite.

Prerequisites:

- Slice C role-scoped discovery and execution enforcement;
- Slice D role-scoped credential resolution;
- prelude attach validation against the role's granted tool set;
- role grant checks that do not depend on lazy upstream catalog materialization;
- an explicit policy for public prelude exports with dynamic upstream calls:
  attach-fail, hide from the prompt-visible surface, or allow with
  execution-time enforcement and log that residual risk;
- logs that prove which role/grant set was active for each turn.

Target invariant:

> A model sees only what its role can call, and the server enforces that same
> policy at execution time.

Dynamic `tool/call` rule:

- public prelude exports with literal `(tool/call {:server "x" :tool "y"})`
  may attach only when the role grants the inferred `upstream:x/y`;
- public prelude exports with dynamic `(tool/call {:server server :tool tool})`
  must attach-fail unless the export carries explicit `:requires` entries that
  can be checked against the role grant;
- exports that carry broad or unknown upstream requirements should stay absent
  from the prompt-visible surface unless the role has a deliberately broad
  matching grant and the turn log records that grant fingerprint.

This is where preludes, roles, credentials, and `mode` meet. A prelude export
may wrap an upstream mutation, but attaching that prelude must not grant the
mutation. If the role lacks the underlying tool, the export should fail closed
at attach or be absent from the prompt-visible surface.

Example:

```clojure
(defn close-ticket [id]
  (tool/github_update_issue {:id id :state "closed"}))
```

A reviewer role without `github_update_issue` must not be able to use that
export merely because a prelude containing it was selected.

Slice E tests:

- prompt-visible prelude exports are absent or attach-fail when their required
  tools are not granted to the role;
- dynamic `tool/call` exports attach-fail without explicit checkable
  `:requires` entries;
- discovery output and execution behavior are consistent for each role;
- the same scenario run through the old external proxy and native role policy
  exposes the same allowed tool set in shadow mode;
- turn logs contain enough role/grant evidence to audit any rejected call.

Recommended order:

1. Slice A: live store snapshot/export.
2. Slice B: evidence projection over logs.
3. Slice C: role-scoped session policy without credential partitioning.
4. Slice D: role-scoped credentials.
5. Slice E: remove the external tool-filter proxy.

Slices A and B directly improve the next demo. Slices C-E are the policy track
and should be designed with smaller security reviews rather than bundled into
the demo mechanics.

## `ptc_runner` Follow-Ups This Demo Should Drive

1. **Audited upstream discovery.** Stage 2 showed that evidence-path discovery
   and boundary hygiene are coupled. Attempts that lacked first-party evidence
   listing pressure-tested the launcher and repeatedly reached host discovery
   surfaces before the accepted run used a neutral manifest workaround.
   `ptc_runner` should provide bounded, turn-log-visible upstream discovery:
   protocol-native resource listing where upstream MCP servers support it, and
   a conventional `list`/`glob` tool shape for file-like evidence lanes that do
   not.
2. **Session-selected capability namespaces.** Promote the future direction in
   `docs/plans/future/prelude-selected-capability-namespaces.md` from cleanup
   idea to a concrete design candidate. Per-session capability visibility would
   be declared in session start and auditable in turn logs, unlike process-level
   CLI allow/deny flags.
3. **Session-mode `catalog_ops`.** Confirm the structural measurement remains
   present in the actual MCP session path used by the demo.
4. **Evidence-reading / eval-preview tax.** The prior run lost multiple turn
   budgets to bounded previews and paged evidence reads. The next loop should
   either propose a prelude/workflow improvement or produce a concrete
   `ptc_runner` request such as result handles, artifact paging/search, or
   better preview controls with audit logging.
5. **Surface-trimming guidance.** If split preludes still increase discovery
   cost, the loop should propose moving value into fewer public exports,
   namespace docstrings, or better introspection summaries rather than adding
   more helpers.
6. **`sample` / `fold-pages` loop duplication.** `paged_base/sample` duplicates
   the page cursor loop used by `fold-pages`, and `paged_audit/reconcile-totals`
   depends on `sample`. Do not naively implement `sample` in terms of
   `fold-pages` unless `fold-pages` first gains early termination semantics;
   otherwise a bounded sample becomes a full scan. The conservative library fix
   is to extract the shared cursor/page loop into a private helper used by both
   public functions.

## Success Criteria

Minimum success:

- split preludes write and attach through declared dependencies;
- a fresh process can validate the dependent prelude;
- fresh read-only analysis/proposal/review stages can inspect stored prelude
  forms without write authority;
- the loop completes a gated MCP-only cycle and writes or edits the intended
  layer with `prelude/edit`.

Strong success:

- the loop proposes the correct layer without human steering;
- `prelude/edit` shows the structural improvements expected over the
  2026-07-03 recipe baseline;
- discovery cost is measured structurally and falls after surface trimming.

Sharp negative result:

- the split surface works mechanically but the model cannot select the correct
  layer, or the discovery tax outweighs reuse. That would mean the next
  `ptc_runner` work is not more prelude machinery, but better discovery,
  summarization, or surface design.
