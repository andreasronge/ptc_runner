# Experiment Platform Affordances

**Status:** future direction, not committed work. Prompted by the
composable-prelude demo runs in `ptc-bench-comparison` (July 2026), which
kept paying the same setup costs per run. Companion docs:
[`audited-upstream-discovery.md`](audited-upstream-discovery.md),
[`prelude-selected-capability-namespaces.md`](prelude-selected-capability-namespaces.md),
[`prelude-edit-expected-base.md`](prelude-edit-expected-base.md),
[`federated-prelude-stores.md`](federated-prelude-stores.md).

## Problem

Every self-improvement experiment so far (analyst → proposer → reviewer →
editor → validator loops over the prelude store) has needed operator-built
sidecar code and server restarts, because run- and role-level policy has no
home in the server:

- **One bearer token, one owner.** HTTP auth accepts a single
  `http_auth_token` (`mcp_server/lib/ptc_runner_mcp/http/auth.ex`,
  `http/config.ex`). Role differences — read-only analyst vs write-capable
  editor, tight vs broad catalog — live in process-wide switches
  (`sessions_allow_prelude_write`, `catalog_mode` in `:persistent_term`), so
  differentiating stages means restarting the server per stage or wrapping it
  in an external stdio tool-filter proxy, as the composable demo did.
- **Store lifecycle is now operator-addressable, but not yet profile-aware.**
  `PtcRunner.PreludeStore` exposes snapshot, restore, diff, and export, and
  the MCP HTTP admin surface can snapshot/export a live server when an admin
  token is configured. That removes the old hand-scripted fingerprint/source
  dump path, but lifecycle verbs still sit outside role credentials and gate
  policy. Experiment launchers must still decide when to capture, compare, and
  attach the resulting manifests.
- **Upstreams must be external processes.** `upstreams_config` wires stdio
  commands, so every fixture or evidence shape needs a hand-written sidecar
  server (the demo's `paged_jsonl_mcp.py` and its per-run variants).
- **Turn-log querying exists, but policy-stamped run identity is still thin.**
  Sessions now accept structured tags and the `log/` prelude can query/counter
  recorded logs, but stage profiles cannot yet require or auto-stamp tags from
  credentials. Gate audits still need launcher discipline to keep run/stage
  tags consistent.

Net effect: each new experiment shape becomes new sidecar code or a
`ptc_runner` change. The composable demo burned 11 Stage 2 attempts, most on
launcher and boundary plumbing around exactly these gaps, before a clean
accepted run.

External confirmation that this plumbing is the binding constraint: the
harness-optimization writeup at
<https://huggingface.co/spaces/joelniklaus/harness-optimization> (Meta-Harness
recipe applied to Harvey's Legal Agent Benchmark; frozen model, automated
harness hill-climb, 63.1% → 83.3% pooled criterion pass on dev). Two of its
operational lessons transfer directly:

- "An LLM optimizer needs the same operational hardening as any long-running
  distributed job: retries, idempotent resume, clean failure, and a guard
  against contaminating held-out data. Without that plumbing, the headline
  number would not hold up." Their optimizer lost iterations to silent auth
  failures; our Stage 2 saga was the same lesson.
- Their worst defect was promoting a candidate by comparing a fresh score
  against stale cached state. The generic countermeasure is cheap
  snapshot/diff/fresh-recompute verbs, not one-off fixes.

That writeup also frames the opportunity: scaffold-layer improvement loops
are an active research direction, and `ptc_runner`'s differentiator is
running such loops over a **typed, versioned, dependency-pinned capability
store with audit** rather than an opaque scaffold — but only if standing up
an experiment is cheap. Today it is not.

## Direction

Target state: a new experiment is **one server boot plus a run directory**
(role credentials, seed preludes, evidence directories, recordings) plus
prompts. No Elixir changes, no Python sidecars, no restarts between stages.
Experiment policy becomes data the server interprets.

Four affordances, ordered by target-state dependency rather than first
implementation order. The test applied to each: which hand-written artifact
from the bench runs does it delete?

### 1. Role-Scoped Credentials

Status: mostly implemented, via `--session-roles` (session mode ceiling,
per-role prelude write permission, tool/upstream subset, preludes) and
`--http-role-tokens` binding multiple HTTP bearer tokens to those roles — see
[`composable-prelude-library-demo.md`](../composable-prelude-library-demo.md)
Slices C and D for the shipped shape. Remaining gap: D2b (projection-scoped
MCP HTTP upstream clients per role) is still open; credential-profile
auto-stamping of required session tags is tracked under affordance 4, not
here.

Support multiple HTTP bearer tokens, each bound to a named profile that pins
session defaults and ceilings:

- session mode ceiling (`read_only` vs `write_capable`);
- prelude write permission (per-token, not process-wide);
- catalog / export visibility;
- tool and upstream subset;
- session limits and required session tags (see affordance 4).

This is the operator-side complement to
[`prelude-selected-capability-namespaces.md`](prelude-selected-capability-namespaces.md):
that direction lets a session *request* a capability surface; experiments
need credentials that *enforce* one, because a gated stage must not be
trusted to ask for the right surface. One running server can then serve an
analyst, proposer, reviewer, editor, and validator with different pinned
surfaces, each attributable in turn logs by owner.

Deletes: the stdio tool-filter proxy, per-stage server restarts, and the
single-owner limit on concurrent stages.

### 2. Store Lifecycle Verbs: Export, Snapshot, Diff, Restore

Status: shipped as the operator/admin baseline. Keep this affordance in the
target-state list because later slices should use the same manifest and
fingerprint format rather than inventing new run-state artifacts.

- **export** — dump the live store to a seed-compatible directory plus a
  manifest of ids, versions, checksums, and dependency pins;
- **snapshot / restore** — capture and reinstate full store state, so a
  failed or contaminated attempt is rolled back with one command and reruns
  are idempotent;
- **diff** — compare two snapshots or a snapshot against the live store,
  reporting changed ids/versions/checksums.

Deletes: hand-scripted fingerprint sessions, per-run source-snapshot
scripts, and the contamination anxiety across attempt reruns. Store diffs
become gate evidence ("this stage changed exactly `paged_audit@1 → @2`").
This is also the experiment-sized down payment on
[`federated-prelude-stores.md`](federated-prelude-stores.md): same format,
same verbs, operator-invoked before any federation exists. And it is the
generic form of the Meta-Harness stale-state countermeasure: promotion and
gating decisions compare freshly recomputed state, never cached numbers.

### 3. Built-In Fixture Upstream Types

Let `upstreams_config` declare data-plane upstreams without an external
process:

- `{"type": "files", "root": dir}` — bounded, paged, read-only access to a
  directory (the ~100-line Python sidecar, as a supported adapter);
- later `{"type": "replay", "recording": path}` — replay recorded upstream
  traffic, with a capture mode that writes recordings from live upstream
  calls (turn logs already record the calls; this makes them replayable).

An evidence bundle or fixture then *is* a directory; preparing one is `cp`.
A built-in adapter can also implement the bounded discovery surface from
[`audited-upstream-discovery.md`](audited-upstream-discovery.md) natively,
so fixture upstreams are discoverable without per-run manifest files.

Deletes: `paged_jsonl_mcp.py`-class sidecars and hand-authored evidence
manifests.

### 4. Session Tags and Turn-Log Querying

Status: mostly shipped as the run-audit baseline. Sessions accept structured
tags at `lisp_session_start`, turn events carry those tags, and the `log/`
prelude can filter and aggregate recorded logs. Remaining work is to make tags
credential-profile-required or auto-stamped so a stage token can enforce labels
such as `run`, `stage`, and `attempt` instead of relying on launcher discipline.

The data already exists on disk; this is tooling, not new instrumentation.
Per-session counters are also the first-party cost signal that any future
cost-adjusted acceptance criterion needs ("does this prelude edit reduce
expected session cost without regressing replay?").

Deletes: file archaeology for boundary audits and M2-style discovery-tax
metrics; both become queries.

Related but tracked separately:
[`prelude-edit-expected-base.md`](prelude-edit-expected-base.md) deletes the
external post-edit parent-checksum checker from every run's gate checklist.

## First Practical Slice: Shipped Baseline

This slice has landed. It deliberately avoided the full role/profile system,
which has the widest security surface: auth, owner identity, catalog exposure,
tool filtering, upstream filtering, session limits, and default stamping all
meet there. The shipped baseline makes single-server attempts inspectable and
repeatable without changing bearer-token semantics:

1. **Prelude store export/snapshot/diff/restore**
2. **Session tags and tag/status/time filters on turn-log queries**
3. **Richer read-only turn-log counters through the `log/` prelude**

This deletes the highest-friction hand scripts while preserving the
single-token policy model. Role-scoped credentials, credential-profile
auto-stamping, and built-in fixture upstreams remain target-state affordances,
but they now build on the manifest/tag/query substrate instead of blocking on
it.

### Slice 1 Investigation Notes

Current code seams are favorable:

- `PtcRunner.PreludeStore` already has stable public verbs for `list/1`,
  `history/2`, `read/2`, `write/4`, `edit/4`, and `set_default/3,4`.
  State lives in `PtcRunner.PreludeStore.Server` ETS rows:
  `{:version, id, version}` for retained candidates, `{:current, id}` for the
  selected version, and `{:latest, id}` for monotonic latest version.
- `PtcRunner.PreludeCandidate.public_view/2` already projects bounded source,
  checksum, metadata, dependencies, origin, and timestamps without exposing the
  compiled prelude struct. That is useful precedent for model-facing views, but
  it is **not** a snapshot format: it truncates source and filters metadata.
  Snapshot/restore needs an exact host/operator format with full source, full
  JSON-safe operational metadata, current/default metadata, and explicit
  checksums.
- `prelude_store_seed` currently imports source files only. It derives ids by
  scanning `(ns ...)`, retries dependency-order failures, then calls
  `PreludeStore.write/4`. A seed-compatible export can therefore write one
  source file per **current** candidate plus a manifest; full snapshots need a
  richer manifest that includes retained historical versions and current
  selection metadata.
- `lisp_session_start` currently accepts `title`, `ttl_ms`, `mode`, `role`,
  `preludes`, and `tags`; unknown args are rejected. Tags are already stored on
  `PtcRunnerMcp.Sessions.Session` and included in turn events. Remaining profile
  work should treat role and tags as already-present launch metadata rather than
  new session-start schema.
- Canonical turn events already carry `session_id`, `driver`, `turn`,
  `attempt`, `committed`, `status`, token fields, and a `data` bag containing
  `tool_calls`, `catalog_ops`, `limits_hit`, `preludes`, and `memory_diff`
  (`PtcRunner.TraceLog.TurnEvent`). `PtcRunner.TraceLog.Analyzer` already has
  `turn_events/1`, `sessions/1`, `session_turns/2`, and `programs/1`; the
  shipped slice adds directory-wide JSONL loading, tag/status/time filters, and
  experiment-oriented counters.
- `PtcRunner.TraceLog.Introspection` already packages turn-log access as the
  read-only `log/` prelude with host-bound tools over a memory sink, JSONL path,
  or loaded event list. `mix ptc.repl --log-prelude` already grants that prelude
  over the REPL's in-memory sink for "analyze my current session" workflows.
  Slice 1 should extend this existing prelude rather than making a Mix task the
  primary interface.

### Slice 1 Implemented API

Root library:

- `PtcRunner.PreludeStore.snapshot(store) :: {:ok, snapshot}`
  returns a JSON-safe map with `schema_version`, `created_at`, store limits,
  current selections, retained versions, checksums, dependency pins, source,
  metadata, and created/updated timestamps.
- `PtcRunner.PreludeStore.restore(snapshot, opts \\ []) :: {:ok, store}`
  creates a fresh volatile store through an internal import path that preserves
  exact retained version numbers, gaps, latest pointers, current selections,
  dependency pins, and checksum-reuse safety behavior. Do not implement restore
  by replaying public `write/4`: retained histories may have gaps, and pins are
  version-exact.
- `PtcRunner.PreludeStore.diff(left, right_or_store) :: map`
  reports added/removed/changed ids, current-version changes, source-checksum
  changes, dependency-pin changes, and metadata/default-selection changes.
- `PtcRunner.PreludeStore.export(store, dir, opts \\ []) :: {:ok, manifest}`
  writes current source files plus a seed-compatible manifest carrying ids,
  versions, checksums, dependencies, defaults, and the aggregate store
  fingerprint. Filenames are deterministic filesystem transport; the manifest
  is the authority.

MCP server / tools:

- Store lifecycle commands are operator-facing first, exposed only through the
  admin route (absent unless a separate admin token is configured) — see
  [`composable-prelude-library-demo.md`](../composable-prelude-library-demo.md)
  Slice A for the route/auth shape; this doc covers the library functions the
  route calls. Offline tasks can still operate on seed directories or snapshot
  files, but they are not a substitute for an in-VM admin path when inspecting
  an already-running volatile store.
- Extend existing session tags into credential-profile requirements and
  auto-stamping in a later role-credentials slice. `lisp_session_start` already
  accepts bounded scalar tags and MCP session turn events already carry
  top-level `"tags"`; remaining work is to let trusted profiles require or
  inject tags such as `run`, `stage`, and `attempt`.
- Keep tags part of the canonical turn-event contract, not an MCP-only detail.
  Query code must continue to handle mixed tagged and untagged logs.
- Extend the `log/` prelude/tool grant as the canonical query interface:

  ```clojure
  (log/sessions {:tags {"run" "demo-07" "stage" "editor"}})
  (log/turns "sess_abc123" {:status "error" :limit 20})
  (log/counters {:tags {"run" "demo-07" "stage" "editor"}})
  ```

- Directory sources in `PtcRunner.TraceLog.Introspection.tools/2` let a host
  grant one run's `turn-log` directory as the evidence source. The model queries
  the granted source; it does not get arbitrary filesystem access.
- Directory loading should be deterministic: load `*.jsonl` files in sorted path
  order, apply one aggregate `:max_bytes` cap across all files, fail closed on
  malformed JSONL by default, and filter before pagination. If duplicate events
  become possible, deduplicate only on a documented stable identity such as
  `{trace_id, seq}`.
- `log/counters` is a first-class prelude export and host tool, not only an
  example. It applies the same filters as `log/sessions`/`log/turns`.
- Keep a Mix task optional and thin, for non-model shell/CI gates. It should call
  the same analyzer/introspection code rather than becoming a second query
  implementation.
- `mix ptc.repl --log-prelude --log-source PATH` grants an explicit recorded-log
  source where `PATH` is a JSONL file or turn-log directory. That lets a human
  or model use the same `log/` prelude interactively over previous runs, not
  only over the current REPL's in-memory sink.
- Do not generalize REPL prelude selection in this slice. The better long-term
  interface is a generic capability/prelude selection surface instead of one
  flag per built-in feature (`--log-prelude`, future store preludes, etc.), but
  that likely touches composition semantics, host-tool grants, prompt inventory,
  and namespace/export conflict handling. Keep `--log-prelude` as the narrow
  bridge until general prelude selection is designed.
- Explicit non-goal: Slice 1 does not allow `mix ptc.repl --log-prelude
  --prelude domain.clj`. Prior-run log analysis in the REPL remains log-only
  until generic prelude composition exists.

### Slice 1 Counter Definitions

Keep first counters boring and derivable from existing event shapes:

- `attempts`: count of matching `event == "turn"` records.
- `committed`: count where `"committed" == true`.
- `failed`: count where `"committed" == false`.
- `catalog_ops`: sum of `length(event["data"]["catalog_ops"])`.
- `tool_calls`: sum of `length(event["data"]["tool_calls"])`.
- `upstream_calls`: count tool calls whose `"server"` is not nil and not the
  local Lisp/prelude pseudo-surface, pending a stricter upstream marker.
- `duration_ms`: sum of turn `duration_ms` where present.
- `input_tokens`, `output_tokens`, `total_tokens`: sums of top-level token
  fields where present.

Do not claim stable cross-version cost semantics yet. The query output should
include `schema_version` and server/app version when available so later
benchmarks can reject incomparable counters.

### Slice 1 Acceptance Criteria

- A seeded store can be snapshotted, restored into a fresh store, and diffed
  back to empty changes.
- A store with dependencies and a non-latest current/default version restores
  with the same current refs and dependency pins.
- A store with pruned history gaps, for example retained versions `[1, 10, 11]`,
  restores with the same version numbers, latest pointer, and pin targets.
- Same-source pin-only rewrites preserve stale-base safety after restore: a
  checksum-only write that was ambiguous before snapshot remains rejected after
  restore.
- Snapshot/restore preserves exact source even when source exceeds the bounded
  model-facing `public_view/2` read size.
- Exported current-source files can be used as `prelude_store_seed` input for a
  fresh boot; the manifest preserves the richer state that seed files alone
  cannot.
- A current dependent pinned to a non-current dependency version either exports
  seed-compatible dependency sidecars or fails closed with a clear explanation
  that current-source seeding would not preserve the pin.
- `lisp_session_start(tags: ...)` rejects malformed or oversized tags, stores
  valid tags, and each emitted turn event carries those tags.
- Mixed tagged and untagged logs query correctly; untagged turns are omitted
  only when tag filters require a value.
- The `log/` prelude can filter by tag and session over a granted JSONL file,
  event list, memory sink, or turn-log directory and emit deterministic
  counters.
- `log/counters` filters before aggregation and returns the Slice 1 counter set
  deterministically.
- `mix ptc.repl --log-prelude` continues to work for current-session
  introspection; later `--log-source PATH` support can grant recorded logs to
  the same prelude without adding a separate query language.
- Generic operator correlation tags such as `run`, `stage`, and `attempt` may
  enter turn logs. Gate-side approval, expected labels, answer keys, holdout
  identifiers, and gate decisions must not enter the store manifest or turn-log
  query API.

## What This Enables

- **Experiments as configuration.** Held-out-issue batteries become cheap:
  dangling guidance references, paging-semantics bugs, surface-trimming
  cases, and `no-change` traps can each be a run directory instead of a
  bespoke build-out. More runs per unit of operator effort is the difference
  between one n=1 demonstration and a measured rate.
- **Multi-role loops on one server**, with each stage's surface pinned by
  credential and every action attributable in turn logs — the audit story
  scales with the loop instead of eroding as stages multiply.
- **Idempotent attempts with provenance.** Snapshot/restore makes failed
  attempts free; export/diff makes accepted attempts self-documenting.
- **A substrate for automated outer loops.** A Meta-Harness-style proposer
  population hill-climbing over the prelude store — automated search below
  the library boundary, human gates at it — needs exactly these verbs:
  restore a baseline, run candidates, replay-validate, diff, recompute
  fresh, promote. None of that should be per-experiment code.
- **Production legitimacy.** Role-scoped tokens, store export, file-serving
  upstreams, and log queries are ordinary operator features. Nothing here is
  test rigging, so nothing here weakens production posture.

## Boundary: No Demo Mode

Gates, redaction policy, holdout keys, answer keys, and stage orchestration
stay **outside** the server, in the bench/launcher layer. The server not
knowing it is part of an experiment is what keeps boundary audits credible;
a `ptc_runner` that grew experiment awareness would put an asterisk on every
result produced with it. The inclusion test for this doc's affordances is
that each is just as legitimate in production as in a bench run.

## Open Questions

- Credential/profile configuration format: flags stop scaling at multiple
  tokens; a config file implies a story for rotation and reload.
- What belongs in an export manifest beyond ids/versions/checksums/pins —
  keep gate-side provenance (who approved, on what evidence) outside the store
  manifest for slice 1; revisit only with the federated-store provenance
  design.
- Replay matching semantics: exact argument match, normalized match, or
  adapter-defined?
- Counter definitions stable enough to compare across runs and server
  versions (what exactly counts as one "discovery op")?
