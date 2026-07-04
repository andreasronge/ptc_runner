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

The `5055deac` baseline fixes measurement and read-only prelude introspection,
but it is not yet a full experiment platform or policy gateway:

- no role-scoped credentials or per-role upstream authority;
- no native replacement for the external MCP tool-filter proxy;
- no built-in evidence/fixture upstream beyond the existing trace-log
  introspection surface;
- no live MCP admin endpoint for snapshotting/exporting the already-running
  HTTP server's volatile `PreludeStore` from outside the BEAM VM.

The current store lifecycle verbs are library/operator APIs:
`PtcRunner.PreludeStore.snapshot/1`, `restore/2`, `diff/2`, and `export/3`.
The MCP server can also seed a volatile store at boot via
`--prelude-store-seed`. That is enough for local operator code and
boot-time reproducibility, but not enough for an external experiment harness to
capture a live server's store state without VM access.

## Recommended Independent Implementation Slices

These should land as independent slices. Each slice should have its own tests,
docs, and turn-log/audit story, and none should require the others to be useful.

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

`log/counters` remains the low-level metrics primitive, but Slice B should fix
its token field semantics rather than only documenting them. MCP-driven sessions
generally have unknown `input_tokens`, `output_tokens`, and `total_tokens`
because the MCP server does not see the host LLM tokens. The counter output
must distinguish unknown from observed zero, either by returning `nil` for a
token total when no integer observations exist or by adding `*_known_count`
fields. For MCP-session cost signals, use `duration_ms`, `attempts`,
`tool_calls`, `catalog_ops`, and upstream-call counts; do not treat unknown
token fields as zero-token execution.

Slice B tests:

- evidence bundle reads are recorded in turn logs with bundle id, checksum,
  source path/ref, and byte counts;
- malformed selection/redaction specs fail closed before serving evidence;
- all paged evidence APIs use `items`/`next_cursor`/`has_more`/`limit`;
- `log/counters` filters by tags before aggregation and preserves unknown token
  semantics instead of collapsing missing token observations to zero;
- a model can compute stage metrics with
  `(log/counters {:tags {"run" "..." "stage" "..."}})` without hand-prepared
  metrics files.

### Slice C — Role-Scoped Session Policy

Goal: introduce a first-class role/grant model without changing credential
storage yet.

Recommended first pass:

- add a session `role` field with a configured grant map;
- filter upstream discovery by role;
- enforce the same grant at execution time;
- echo accepted `role`, normalized `tags`, and grant fingerprint in
  `lisp_session_start` responses;
- record role and grant fingerprint in session start and turn logs;
- keep credential resolution process-wide for this slice, but verify a role
  cannot call ungranted tools even when the upstream runtime knows they exist.

Conceptual config:

```json
{
  "roles": {
    "analyst": {
      "upstream_tools": ["evidence/read-summary", "evidence/read-turns"],
      "prelude_modes": ["read"]
    },
    "editor": {
      "upstream_tools": ["evidence/read-summary"],
      "prelude_modes": ["read", "write"]
    }
  }
}
```

`mode` remains narrower than `role`: `mode: "write_capable"` controls the
built-in prelude authoring surface, while `role` controls the wider upstream
tool set a session may discover and execute.

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

- `lisp_session_start` rejects unknown roles and malformed role values;
- accepted role/tags/grant fingerprint are echoed in start response;
- turn events include role, tags, and grant fingerprint;
- discovery hides tools not granted to the role;
- execution rejects an ungranted tool even if the upstream runtime can call it;
- `mode: "write_capable"` remains insufficient to grant unrelated upstream
  tools.

### Slice D — Role-Scoped Credentials

Goal: bind credentials to roles after role-level tool enforcement exists.

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

- role-facing catalogs, prompts, turn logs, and evidence bundles should expose
  only non-secret grant fingerprints, not raw credential binding ids;
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
- credential ids/secrets never appear in model-facing prompts, turn logs, or
  evidence bundles except as bounded non-secret grant fingerprints.

### Slice E — Native Tool-Filter Replacement

Goal: remove the external MCP tool-filter proxy once the server owns both
discovery filtering and execution enforcement.

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
