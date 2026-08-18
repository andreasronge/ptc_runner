# TraceLog and Run Analysis — V2 Contract

**Status:** implemented retained product contract, including the local 0.x
inspection increment. Complements `PtcRunner.Kernel.TraceLog` module
documentation and the Kernel maintainer guide, `docs/maintainers/kernel.md`,
which is a repository document rather than a page the executable carries.

## Purpose and boundary

TraceLog preserves bounded, queryable facts about Kernel runs for humans,
automated diagnostics, and explicitly authorized PTC-Lisp workflows.

```text
Kernel and capability providers
  emit canonical bounded events

TraceLog
  stores, sanitizes, loads, indexes, filters, and bounds event queries

Consumers
  ptc_viewer, CLI/debug tools, and the shared analysis/* capability surface
```

Kernel does not know how traces are stored or queried. TraceLog does not control
workflow execution. Consumers do not invent competing event representations.

## Observability planes

PtcRunner keeps four observability concerns separate:

- the host logger, reports sparse operational
  diagnostics such as unexpected host failures and degraded optional services.
- `:telemetry` reports low-cardinality measurements for embedders and host
  monitoring. It is not an event store or an authorization boundary.
- `Kernel.EventSink` and `Kernel.TraceLog` own the canonical bounded run event
  journal consumed by `ptc_viewer`, CLI diagnostics, and `analysis/*`
  capabilities.
- the opt-in `Kernel.InspectionSink` owns exact sensitive development
  payloads under the separate controls below.

These are different planes, not interchangeable logging implementations.
Canonical events are not implemented by forwarding Logger messages or
Telemetry callbacks: neither supplies the retention, sequencing, bounds,
source grants, or fail-closed policy required by this contract. Conversely,
canonical events are not mirrored wholesale into Logger or Telemetry.

All planes may share run, evaluation, and capability correlation IDs, subject
to their own cardinality rules. Logger and Telemetry never add prompts,
generated source, capability arguments/results, credentials, transport
headers, session IDs, or endpoints. Exact application payloads appear only in
an explicitly enabled inspection artifact. Owner processes that retain private
inspection/evaluation values or connector endpoint/session state use closed
callback fallbacks and constant redacted OTP status, including abnormal-exit
reports. Erlang VM tracing (`:erlang.trace`, `:dbg`, or `:sys.trace`) is an
operator debugging facility, not a product trace source.

The Lisp execution Telemetry prefix is `[:ptc_runner, :lisp, :execute]`. Its
closed `caller` values are `:direct`, `:kernel`, and `:repl`. Stop metadata
carries the semantic `outcome` (`:ok` or `:error`) while measurements carry
duration, program/result byte counts, and print count. Exception telemetry may
identify the exception class but does not attach the raw reason, stacktrace,
source, arguments, or result. These events are metrics for embedders, not the
source used to reconstruct a run.

The Viewer has one canonical event model. The inspection loader is not a
replacement trace schema; it joins private records to canonical IDs.

## Canonical authority

The append-only canonical event stream is authoritative. Derived run metadata,
counters, indexes, and viewer projections must be rebuildable from it.

An index may accelerate discovery and pagination, but it:

- is never the sole copy of run facts;
- records the source identity/version it indexes;
- is invalidated or rebuilt when its source changes;
- does not silently merge unrelated trace sources;
- cannot grant access beyond the underlying source grant.

Do not maintain a second authoritative session/run database.

## Storage sources

The current trace schema supports:

- append-only JSONL files;
- explicitly granted directories containing JSONL files;
- a bounded in-memory sink for REPL, tests, and short-lived runs.

JSONL files are written in canonical sequence order. Directory loading is
deterministic: discover supported files, normalize paths, sort them, then load
in sorted order under one aggregate byte cap.

One directory holds both sanitized and private trace files, and one source
grant reads exactly one kind. A run listing and a counters query therefore
report the trace files that grant refused to read, as
`excluded_private_trace_files` on a sanitized source and
`excluded_sanitized_trace_files` on a private-only source. The field is absent
when nothing was excluded, and inspection artifacts are never counted: they are
a separate artifact class rather than withheld runs. Run-scoped answers never
carry the field. The count is advisory evidence about the directory, not part
of the source identity, so a concurrent write to the kind a grant does not read
never invalidates the evidence it does read.

Normal trace sinks sanitize before persistence. Private canonical event sinks
use the separate fail-closed policy specified by the event-sink section of the
`PtcRunner.Kernel.EventSink` module documentation, but retain the same event
vocabulary rather than capturing exact payloads or source.

Malformed or unsupported canonical events fail closed by default. A debugging
mode may report bounded per-file errors, but it never silently reinterprets
malformed data as valid runs.

Ordinary host-selected append uses an OS-released advisory lease before it
validates the existing prefix and writes a batch. Existing files are keyed by
device and inode, so hard-link aliases share the lease across BEAM processes
and separate local runtimes. An unlocked lease file may remain after exit, but
cannot wedge later appenders. Two appenders therefore cannot both approve the
same prefix and then race the byte or sequence checks.

Complete analysis-session batches use atomic no-clobber publication rather than
append. TraceLog validates and deterministically encodes the whole batch, writes
and syncs an exclusive same-directory temporary sibling whose name is not a
discoverable trace, installs the final name with a hard link, and syncs the
containing directory before reporting success. Removing the temporary link is
followed by another directory sync. An existing byte-identical complete
destination is a successful retry only after the directory is synced; a
different or partial destination is a collision and is never replaced or
appended. The open temporary descriptor, temporary pathname before linking, and
published pathname after linking must retain the same device/inode identity;
pathname replacement is a collision and is never acknowledged as successful.
Observed failure paths remove the temporary sibling. This publication contract
is for host-selected destinations only and does not grant Lisp write authority.

### Immutable canonical-directory captures

An internal trace-snapshot owner can pin one host-selected canonical trace
directory for a bounded analysis session. It is not an additional public
`PtcRunner.Kernel.TraceLog.source()` form and cannot capture a file or
inspection artifact. The constructor fixes whether that directory is ordinary
normal-only input or private-authorized canonical input; a caller cannot widen
an existing snapshot handle or relabel it for another analysis profile.

Ordinary capture enumerates supported normal `.jsonl` names in canonical sorted order,
records a pre-read directory/file inventory, opens only regular files, compares
path and descriptor identity, retains the baseline bytes, and performs a second
byte-for-byte verification around a final inventory check, followed by one last
content verification after that inventory. A name, identity, metadata, type, or
content change between the baseline and final verification returns
`:source_changed`; it never installs a mixed capture. The complete
decoded event set is normalized and validated exactly once before the owner
becomes queryable. Private `.private.jsonl` and `.inspection.jsonl` artifacts
remain excluded by the ordinary normal-directory discovery rules. The internal
private-authorized capture instead selects both ordinary and
`.private.jsonl` traces, records `sanitized` or `private` provenance per run,
and still rejects inspection artifacts. A run cannot be split across the two
trace classes.

The default aggregate encoded-source ceiling remains 8,000,000 bytes. Capture
enumerates under a fixed heap and time bound, and rejects directories above
4,096 total entries or 1,024 selected trace files before sorting,
stating, opening, or verifying selected files. Snapshot retention independently
limits the decoded representation to 32,000,000 retained bytes, and query
results retain the existing 1,000,000-byte default. These values are hard
ceilings: hosts may lower the internal construction limits but cannot raise
them, and browser or Lisp input cannot select them.

The owner retains only validated events, their digest, fixed query limits, safe
capture metadata, and an owner monitor. Its tokenized handle contains only a PID
and unforgeable reference; neither owner state, status output, capability
closures, safe metadata, nor errors retain or expose the directory path. Safe
metadata contains the capture digest, UTC capture time, visible run count, raw
encoded source bytes, and retained decoded bytes. Owner death cancels an
in-progress capture worker as well as stopping an installed snapshot.

All four snapshot queries execute the same TraceLog filtering, metadata,
ordering, pagination, cursor, and result-limit code as ordinary sources. Cursors
bind to the captured digest and therefore remain stable when the original
directory changes later. The snapshot exits with its owning analysis session;
cleanup is idempotent. This immutable boundary also prevents an analysis run's
new canonical events from mutating the source it is paging.

### Local analysis sessions

The server-owned `run-analysis-v1` profile is shared by the Viewer and ordinary
terminal REPL frontends. Its mission bundle contains `cap` and `analysis`; its
explicit authority contains the three `analysis-*` capabilities; and ordinary implicit
mission introspection remains available. Filesystem, network, LLM, agent,
workflow, MCP, private-inspection, and nested `kernel-eval` authority are
absent. The separate `private-run-analysis-v1` profile uses the
private-authorized canonical capture, adds the validated private-inspection
source while retaining the same analysis component, and requires a private terminal gate.
Its own session trace remains a sanitized normal analysis artifact.

Each session queries one immutable snapshot and records its own canonical events
in the same owner process that holds its continuation and quotas, under a
separate token. The active mutating session trace is never queryable from that
session. The Viewer publishes into its host-configured input directory, so a
later refreshed Viewer session captures the directory again and can query its
predecessor. A terminal `ptc repl` session instead publishes into a
physically separate host-selected or private temporary directory and never
mutates its captured input tree. The builder binds the accepted output
directory's filesystem identity into `SessionTrace`; atomic publication
uses a directory-bound helper whose working-directory identity is verified
before it receives trace bytes. Replacing or retargeting the pathname therefore
cannot redirect the write.
Orderly close, reset, and deadline expiry finalize and publish the batch.
Explicit return and fail are evaluation facts rather
than session lifecycle commands. Exhausting a terminal session budget persists
an error run with that authoritative limit reason, even when abort or deadline
expiry performs the eventual close. Recorder readiness and continuation commit
are one owner callback, so combined-runtime or trace-owner death cannot leave a
committed result without event authority and releases the snapshot. During
orderly close, `SessionTrace` synchronously stops and observes the combined
runtime and snapshot before relinquishing their handles or starting
persistence. The deadline message is privately correlated and cannot be forged
from the session PID alone. Every evaluation admission also checks the same
authoritative deadline before running; expiry therefore closes and publishes
with the same outcome regardless of timer-message ordering. Before the builder
releases its construction guard,
session death cleans partial owners without publishing a run; every post-start
handoff failure explicitly stops the partial session even when the trace owner
has already died. Session information requests serialize behind an accepted
evaluation and do not mistake that bounded wait for owner death.
The trace owner is constructed only when its limits, combined runtime/sink,
normal fail-closed policy, exact two-event measured-envelope terminal reserve, empty unfinalized
recorder, open RunState, sink run/trace identity, and `<run-id>.jsonl`
destination agree. Assembly validation rechecks the runtime binding. The sole
session attaches before `run-started`, so rejected assembly replay is side-effect
free.
Unexpected session-owner death receives one independent best-effort aborted
publication attempt before `SessionTrace` stops. Retryable batch retention is
available only through a still-live session's explicit close path; failed
unexpected-death publication does not leave an unreachable retry owner.
An authoritative terminal-budget reason is transferred to the trace owner
before the triggering evaluation reply and takes precedence over the generic
unexpected-owner reason if death occurs before explicit close.
If resource handoff encounters a combined runtime that died before orderly
`RunState.close/1` was accepted, an otherwise open recorder becomes
`backend_failed` before its monitor is flushed; cleanup cannot erase the
failure signal.
Failure before terminal-batch handoff makes finalization fail without inventing
a retry batch. Failure after the batch is frozen preserves its terminal reason,
events, and persistence state.

The process calling the builder remains the stable lifecycle owner after the
construction guard is marked complete. Its monitor is intentionally retained:
death during the final reply window cannot orphan a completed session, and
later owner death aborts and best-effort persists it. A host must therefore call
the builder from its long-lived connected backend owner rather than a disposable
request or callback task. Close and abort preserve the live session owner for
idempotent persistence retry; the frontend explicitly stops it after its final
close or abort attempt.

Public evaluation prints are projected in one pass under both a 128-entry
ceiling and a 65,536-byte encoded JSON-array ceiling. The truncation flag is
authoritative even when omitted entries are empty strings.

The session EventSink opts into a measured terminal reserve. Ordinary events stop before
the count and byte ceilings would consume capacity for one bounded
`events-dropped` summary and exactly one `run-stopped`; atomic finalization also
returns the frozen terminal batch in that same owner call, without exceeding
either hard ceiling. Existing normal and private sinks retain their original
behavior unless explicitly constructed with the reserve.

A successful `run-stopped` event includes `data.result_hash`: `sha256:` plus
the lowercase SHA-256 digest of the successful result value's deterministic
canonical JSON bytes. `ResultArtifact` writes those same bytes, so a trusted
host can bind an artifact to the run that produced it without exposing the
result in the public trace. Failed runs omit the field.

A shipped `agent.core` loop whose caller propagates exhaustion records
`failure_kind: "turn-limit"`, `limit: "agent_turns"`, the validated
`limit_value` from 1 through 128, and `limit_reason` on the failed
`run-stopped` event. `limit_reason` is one of `turn_limit_exceeded`,
`intermediate_result`, `evaluation_error`, or `protocol_error`, naming what the
final turn produced: a model still working, a program that failed, or no usable
tool call at all. A reason outside that set is dropped rather than recorded.
Other recognized explicit failures retain only their bounded failure taxonomy;
these fields never admit caller-supplied prose.

## Source grants and authority

Trace access is authority-bearing and source scoped. A TraceLog capability is
constructed from exactly one explicit read-only grant:

- one JSONL file;
- one directory root;
- one bounded in-memory sink.

“Available runs” means runs present in the granted source, never every trace on
the host.

The implementation:

- normalizes and confines file access to the granted root;
- rejects traversal, symlink escape, and unsupported file types;
- applies one aggregate input-byte limit across directory files;
- exposes no ambient filesystem operations;
- keeps private canonical event-source access separate and explicit;
- never infers access from visible names, tags, or run IDs.

The `analysis` prelude contains no authority. It requires host run-analysis
capabilities whose source grant provides authority. Missing requirements fail
before workflow code runs.

Trace-query capabilities belong in the mission environment when subordinate
programs may inspect traces. Workflow and mission environments never inherit
each other's trace grants.

## Run identity

Every run has a stable run ID and trace ID. Events carry a monotonic sequence
and timestamp, plus evaluation/capability IDs where applicable.

Canonical loading also validates each run's lifecycle. `run-started` must be
the first event for that run and may occur exactly once. A run may remain open
or end with exactly one `run-stopped`; no event may follow it. Histories that
start late, stop twice, or continue after stopping fail closed as
`:malformed_source`.

Grouping does not depend only on filenames. Duplicate events may be
deduplicated only by a documented stable identity such as `{trace_id, seq}`.

Every event uses schema version 2. `run-started` requires the plural
`missions` metadata map. Every event whose `environment` is `mission` requires
`mission_name`; workflow and lifecycle events forbid it. Unsupported versions
and missing current fields fail closed rather than being inferred or projected.

Every prelude projection on `run-started` — the workflow projection and each
mission's alike — is validated to producer grade rather than interpreted
leniently: unique component IDs, a `dependency_indices` list of the same
length as `component_ids` whose entries are unique and ascending and name only
strictly earlier positions, and a `hash` that is a bare lowercase SHA-256
digest. A nil `hash` means no bundle at all and can therefore name no
components; a bundle always commits to a digest, whether or not it compiled
any component. The projection
is the only canonical commitment a private `prelude-source` record can be
proven against, so a projection that cannot be reconstructed is
`:malformed_source` rather than a weaker fact.

## Required run metadata

`analysis/runs` and `analysis/open` expose bounded sanitized metadata
sufficient to select a run without loading its activity:

- run ID and trace ID;
- start and stop timestamps;
- status and terminal reason when present;
- the successful terminal `result_hash` when present, without the result value;
- workflow/agent name when supplied;
- model and provider identifiers when recorded by a provider;
- total and subordinate-evaluation counts;
- workflow and mission capability-call counts;
- LLM-call summary derived from named `llm-request` events when applicable;
- full-run `llm_usage_total` input, output, and provider-reported cost values,
  with each field omitted unless every successful LLM call reports that field
  and the canonical trace retained every event;
- error count and duration summary;
- one-way fingerprints of caller-supplied name/model/provider labels, plus
  finite canonical tag keys and enumerated values;
- the effective workflow prelude plus a sorted `missions` map. Each mission
  entry contains its prelude component IDs, hashes, compact dependency
  projection, and full/model inventory hashes and byte counts; and
- effective workflow and mission prelude component IDs, hashes, and the
  compact dependency projection (`dependency_indices`, positionally aligned
  with `component_ids`; every entry lists unique ascending indices strictly
  earlier than its own position);
- the run-started event's positive sequence in `positions`, so start-derived
  provenance such as component overrides and prelude identities is directly
  citable without a second turn query. Outcome, error, and aggregate-count
  claims still cite the canonical turns that support them;
- the bounded `component_overrides` recorded at run start, including component,
  base-source, and effective-source identities, so run discovery exposes
  treatment assignment rather than requiring one provenance query per run;
- safe connector snapshots containing public names, effects, schema hashes, and
  snapshot hashes, plus an exact resolved LLM model only when the active model
  adapter attested it as public; no private target,
  endpoint, or session data is included;
- an optional server-owned session-profile ID and SHA-256 authority digest;
- completeness and truncation indicators;
- schema version;
- whether the source is sanitized normal data or an explicitly granted private
  source.

Normal metadata excludes credentials, headers, environment values, callback
terms, arbitrary provider metadata, exact private prelude source, and unbounded
messages/tool results. Absent optional facts remain absent or `nil`.

## Query contract

The shipped analysis prelude exposes a small navigation namespace:

```clojure
(analysis/runs options)
(analysis/open run-id)
(analysis/read run-id options)
```

Examples:

```clojure
(analysis/runs {"status" "error" "tags" {"stage" "failed"} "limit" 20})
(analysis/open "run-id")
(analysis/read "run-id" {"collection" "activity" "limit" 100})
(analysis/read "run-id" {"collection" "turns" "limit" 20})
(analysis/read "run-id" {"collection" "generated_sources"
                         "prelude_call" "workspace/read"})
```

The internal canonical turn and counter readers accept `mission_name`. Run filters
select runs first, then mission matching retains only events attributed to that
mission. Counters—including event/error/run counts, evaluations,
`evaluations_by_mission`, capability calls, and LLM usage—are derived from that
narrowed event set. Workflow and lifecycle events never match a mission filter.

### `analysis/runs`

Discovers runs in the granted source. Filters are limited to run/trace ID,
status, bounded exact-match tags, workflow/agent name, workflow bundle hash,
model/provider when present, timestamp range, limit, and cursor.

The default `view` is `"summary"` and projects each item to `run_id`, `status`,
`duration_ms`, `llm_calls`, `evaluations`, `terminal_reason`, `complete`, and
`truncated`. Set `"view"` to `"full"` for the complete sanitized metadata
record described above. Pagination and filtering are applied before this
presentation projection, so the cursor and selected run set are identical in
both views.

Default ordering is deterministic: newest start timestamp first, with run ID as
a stable tie-breaker.

### `analysis/open`

Returns metadata for one source-visible run or a uniform not-found/denied error.
It does not return all evidence implicitly. Its `collections` catalog names
each collection, its authority, availability, exact filters, and stable order,
so a caller can discover the next read without knowing the storage schema.
Every descriptor also names `snapshot_domain`, `sequence_domain`, and an
`identifier_locations` map. `canonical_trace` sequences belong only to the
canonical run event stream. `private_inspection` sequences belong only to one
inspection artifact. The `turns` descriptor instead reports
`sequence_domain: "reconstructed_stream"`: `{stream_id, turn}` is its identity,
while its request/response sequence fields remain in the private-inspection domain.
Identifier locations use dotted paths, with `[]` marking values nested in a
list, such as `generated[].evaluation_id` on a turn.
The `model_exchanges` and `capability_calls` entries additionally advertise
`item_completeness_field: "complete?"`; collections without per-item
completion semantics omit that catalog field.

### `analysis/read`

Returns one native bounded page from the named collection. Every page has
`items`, `next_cursor`, `truncated`, `omitted_count`, and `snapshot_hash`;
callers follow `next_cursor` explicitly. The wrapper does not aggregate pages,
diagnose failures, or hide primitive pagination. `limit` is an item-count upper
bound, not a promise: the query may return fewer items so the complete page,
including snapshot metadata, fits both its encoded and retained-size ceilings.

`activity` is public canonical activity in ascending sequence. Private captures
also advertise `turns`, `model_exchanges`, `capability_calls`,
`provider_exchanges`, `generated_sources`, `prelude_sources`,
`execution_prints`, and `execution_errors`. Public recipes report those private
collections as unavailable and reject reads without changing authority.

Every raw `model_exchanges` and `capability_calls` item carries `complete?`.
Completed items retain their result, output sequence, and output timestamp.
An interrupted input-only attempt has `complete?: false` and omits those three
terminal fields. When a callback raised under inspection authority, the item
also carries an `exception` object plus `exception_sequence` and
`exception_timestamp`; these fields remain present if interruption occurred
after the exception evidence was retained but before the normalized output was
retained. Items without such evidence omit the fields rather than setting them
to null. The run metadata counts all admitted attempts and separately reports
`capability_exceptions`, `incomplete_model_exchanges`, and
`incomplete_capability_calls`, including zero on complete runs.

`turns` is the only compiled convenience collection. Each item is one model
turn with the newly added messages, response, matching generated programs, and
stable stream/turn identity. Turn numbers start at one independently within
each reconstructed stream; `{stream_id, turn}` is the identity, while
`request_sequence` only orders records inside the inspection snapshot. It must
not be compared with canonical activity sequence numbers. A turn carries the
`system` prompt that shaped it. Each returned page is compacted on its own,
after filtering and pagination, so every stream present in a page starts with
its effective prompt and an unchanged prompt is not repeated on every turn.
An elided `system` therefore means "unchanged since the last turn in this page
that carried one", never "none was sent": stream linkage keys on the request
messages alone, so one stream can span turns whose evaluated program supplied
different prompts. Compaction is idempotent, so a presented conversation
re-compacts the pages it collected without losing a prompt at a page seam.
Exact raw model requests remain available through `model_exchanges`. Page-level
`evidence` reports canonical completeness, missing exchanges, and ambiguity
separately from pagination. Interrupted model inputs remain raw evidence but
are excluded from `turns`, so the canonical missing-exchange count records the
gap instead of a fabricated assistant response.

Generated programs carry `prelude_calls_available?` and a sorted
`prelude_calls` list of `{ref, component_id}` entries. Exact
`prelude_call`/`prelude_component` filters work on both `generated_sources` and
`turns`. The association between a turn and generated source is explicitly
`source_match`; duplicate identical sources are marked ambiguous rather than
given a fabricated causal identity.

Private execution errors, generated programs, and effective prelude sources may
carry a `relationships` list. Each relationship has this closed shape:

```json
{
  "rel": "direct_boundary_producer",
  "semantics": "causation",
  "target_collection": "activity",
  "filters": {"evaluation_id": "mission-evaluation-id", "status": "returned"},
  "state": "complete"
}
```

The closed relation IDs are `boundary_failure`, `child_evaluations`,
`dependency_prelude_source`, `direct_boundary_producer`, `generated_source`,
`producing_turn`, and `referenced_prelude_source`.
`target_collection` and non-null `filters` are the exact options to add to the
same run's next `analysis/read`; callers must not follow a null filter. State is
one of `complete`, `incomplete`, `ambiguous`, or `unavailable`. Ambiguous
producer candidates are emitted as separately followable exact filters, each
marked `ambiguous`, rather than as an unbounded scan.

Semantics are intentionally narrower than the relation names. `causation`
requires a workflow boundary failure or a direct-return origin marker plus
exact equality with the retained successful `kernel-eval` result. A direct
producer is complete only when the canonical trace proves that the workflow
evaluation stopped with `error` and that the named mission evaluation is
parented by it and stopped with `returned` or `continued`; the exact activity
filters retain those runtime statuses. A canonically successful workflow makes
both causal relations unavailable. `nesting` is reserved for the validated canonical
`parent_evaluation_id` edge.
`association` covers source identity, static prelude references, and the
generated-source/turn source match. A source match can be ambiguous; a parent
edge alone is never promoted to causation. Truncated producer evidence is
`incomplete`, a complete search with no match is `unavailable`, and no relation
compares canonical and inspection sequence values.

`dependency` is reserved for the frozen prelude graph. Each effective prelude
source carries one `dependency_prelude_source` relation per direct dependency
recorded at run start. A component ID alone is not an occurrence identity — the
same component can be frozen into the workflow environment and into several
missions with different dependency edges — so every filter set repeats the
owning `environment` and, for a mission occurrence, its `mission_name`. The
edges are read only from a graph that satisfies the complete positional
contract: `dependency_indices` aligned with unique `component_ids`, and each
entry holding unique ascending indices strictly earlier than its own position.
A graph that is absent, or that violates any part of that contract, yields one
`incomplete` relation with null filters rather than a guessed edge. A component
with no dependencies yields an empty list, which is a different claim from
`incomplete`.

Generated entries embedded in `turns` carry the same `relationships` list as
the matching `generated_sources` item, so a walker that starts from a turn can
follow evidence without an extra exact read to obtain the links.

Provider response usage omits `total_cost` when pricing is unavailable. A
present zero is therefore a measured zero-cost response, not an unknown cost.

The canonical LLM usage summary is shared by trace counters and the V2 run
envelope's `execution.usage`. For routed `llm-request` calls, `llm_usage` groups
stopped events by model alias and installation revision. Each row reports total
and successful calls, calls with valid usage, successful calls missing usage,
and sums of the closed `input`, `output`, `cache_creation`, `cache_read`, and
`total_cost` fields. A row includes aggregate `total_cost` only when every
successful call has valid usage that reports cost; otherwise cost is unknown
and omitted. A revision change creates a separate row rather than silently
combining unlike deployments.

`llm_usage_by_model` groups the same eligible stopped calls by the exact
adapter-attested `resolved_model` stored in that run's LLM provider snapshot.
Rows use the same call, success, usage-presence, and closed usage-sum fields as
`llm_usage`, replacing alias and revision with `resolved_model`, and sort by that
string. Equal model targets combine across aliases and installation revisions;
different targets remain separate even when an operator reused one revision.

Correlation is run-scoped through `{run_id, alias, installation_revision}` and
accepts exactly one current LLM snapshot whose closed shape and two identity
hashes verify. Missing, private, legacy, malformed, hash-inconsistent, replay,
custom, or duplicated mappings do not fail the query. Their otherwise
`llm_usage`-eligible calls increment `unattributed_model_calls`. Consequently:

```text
sum(llm_usage_by_model[*].calls) + unattributed_model_calls
  == sum(llm_usage[*].calls)
```

Snapshot lookup uses all events from the run-filter-selected runs before a
mission filter narrows counted calls. Capability events continue to carry only
alias/revision routing identity; they do not duplicate model identity. The
additional rows remain subject to the existing aggregate result-byte limit.
The command envelope additionally publishes `llm_usage_state`; unavailable or
invalid terminal evidence produces `"unavailable"` with null aggregate fields,
whereas a validated run with no calls produces `"available"`, empty arrays,
and zero unattributed calls.

## Pagination, ordering, and bounds

Every collection query has:

- a conservative default and hard maximum limit;
- a deterministic opaque cursor;
- deterministic ordering and tie-breakers;
- maximum encoded and retained result sizes under one result ceiling;
- truncation and omitted-count metadata, which report pagination only and
  never source-kind exclusion;
- one aggregate source-read byte cap;
- bounded filter/tag/name lengths and counts.

A cursor is bound to the source identity, query operation, and normalized
filters that produced it. Changing filters or reusing a cursor for another
operation fails as an invalid query; changing the source fails as
`source-changed`. The caller may reduce or increase the page limit within the
hard maximum without changing the selected result set.

If a page would exceed either result-size measurement, return the largest valid
prefix plus explicit truncation/next-cursor metadata, or a stable bounded error
when even one item does not fit. Sizing covers the final page shape, including
snapshot metadata. Never build an unbounded result and truncate only after
allocation.

Preview fields are bounded independently. Arguments/results, messages, prints,
memory diffs, and program source follow their own projection ceilings.

## Capabilities and swappable preludes

Analysis capabilities follow the standard Kernel envelope and are named
`analysis-runs`, `analysis-open`, and `analysis-read`.

All three delegate to `PtcRunner.Kernel.RunAnalysis`. The `analysis` prelude is a
thin `cap/unwrap!` layer; Viewer, CLI, and embedders call the same read model.
Capability error envelopes fail evaluation rather than flowing into projections
as ordinary empty data.

Preludes may change ergonomics, projections, defaults, or analysis policy. They
cannot expand the source grant, bypass bounds/sanitization, or acquire private
trace access.

## Events and private data

The generic Kernel emits lifecycle, subordinate-evaluation, capability,
resource, annotation, and terminal facts. Providers may attach safe typed
metadata without making Kernel understand provider-specific transcripts.

A `capability-stopped` event with `status: "error"` carries the closed Lisp
envelope `kind` and, when present, `reason` — the same payload-free class
`execution_errors` already expose. An unrecognized envelope atom is retained
only as a one-way fingerprint (`kind_fingerprint` / `reason_fingerprint`).
Arguments, results, details, and messages stay off this event. Successful
stops omit these fields.

The implemented private event policy stores the same canonical event
vocabulary as the normal policy. It changes sink failure behavior, file
permissions, and discovery; it does not capture prompts, responses, capability
payloads, generated programs, or prelude source. Private JSONL destinations are
restricted to owner read/write permissions before any event payload is
appended. They use the reserved `.private.jsonl` suffix, and normal
file/directory sources and Viewer discovery reject or omit that suffix.

### Implemented 0.x developer-inspection contract

Sanitized subordinate `evaluation-started` data adds:

- `parent_evaluation_id` — the enclosing workflow evaluation ID when the
  subordinate evaluation was launched through the workflow's `kernel-eval`
  route; the matching `evaluation-stopped` event repeats this ID;
- `source_hash` — lower-case SHA-256 hex over the exact UTF-8 source bytes passed
  to `Lisp.run_native/2`;
- `source_bytes` — `byte_size(source)` over those same bytes; and
- `program_kind: "ptc-lisp"` alongside the existing
  `environment: "mission"` and `evaluation_id`.

It must not contain exact source. The `activity` collection returns canonical event
data, so embedding source in a supposedly private event would collapse source
authorization into the ordinary activity query.

Private `generated_sources` copy `parent_evaluation_id` only from that
canonical start event, and reconstructed `turns` can be filtered by either the
child `evaluation_id` or its `parent_evaluation_id`. Thus an execution error's
workflow evaluation ID can select its child programs and turns without
comparing canonical and inspection sequence numbers. The edge proves nesting,
not that a particular child caused the workflow error.

Canonical loading validates the edge before exposing it: the parent must be a
preceding, still-open workflow evaluation in the same run, only a mission
evaluation may name it, and a matching child stop must repeat the same parent.
Orphaned, cyclic, wrong-environment, or contradictory edges make the source
malformed rather than becoming navigation evidence.

Optional sensitive development capture uses a separate private inspection
record stream, not a canonical event. Every `.inspection.jsonl` line is one
JSON object with this exact envelope:

```json
{
  "schema_version": 7,
  "run_id": "run-id",
  "trace_id": "trace-id",
  "sequence": 1,
  "timestamp": "2026-07-16T12:00:00.000000Z",
  "record_type": "capability-input",
  "correlation": {"capability_id": "capability-id"},
  "payload": {}
}
```

Keys are exact. `sequence` is positive and strictly increasing within the
artifact. The timestamp is UTC ISO 8601. Except for `run-result`,
`correlation` contains exactly one of `capability_id`, `evaluation_id`, or
`component_id`. Capability and evaluation values must occur in the canonical
trace for the same run unless that trace explicitly proves the corresponding
start events were dropped. A component value must occur in the canonical
`run-started` prelude component IDs for the record's environment. The current record
types and payloads are:

| Record type | Correlation | Exact payload fields |
| --- | --- | --- |
| `capability-input` | `capability_id` | `environment`, `name`, `arguments` |
| `capability-exception` | `capability_id` | `environment`, `name`, `exception_class`, `message`, `message_truncated`, `stacktrace`, `stacktrace_truncated` |
| `capability-output` | `capability_id` | `environment`, `name`, `result` |
| `evaluation-source` | `evaluation_id` | `environment`, `program_kind`, `source`, `source_hash`, `source_bytes` |
| `evaluation-analysis` | `evaluation_id` | `environment`, `mission_name`, `prelude_calls` |
| `prelude-source` | `component_id` | `environment`, `source`, `source_hash`, `source_bytes` |
| `mcp-request` | `capability_id`, `request_id` | `transport`, `body` |
| `mcp-response` | `capability_id`, `request_id` | `transport`, `body` |
| `execution-prints` | `evaluation_id` | `environment`, `prints`, `truncated` |
| `execution-error` | `evaluation_id` | `environment`, `kind`, `reason`, `details` |

Named-mission ownership is explicit. Mission `capability-input`,
`capability-exception`, `capability-output`, `evaluation-source`, `evaluation-analysis`,
`prelude-source`, `mcp-request`, and `mcp-response` payloads require
`mission_name`; workflow payloads forbid it.
Prelude uniqueness is `(environment, mission_name, component_id)`, so the same
component ID can be inspected independently in multiple missions. Every
mission-owned query result preserves `mission_name`.

V7 retains the successful terminal-result record introduced in V6, at most one
per run:

| Record type | Correlation | Exact payload fields |
| --- | --- | --- |
| `run-result` | empty map | `result_hash`, `value` |

The value must already be strict JSON: string-keyed maps, lists, strings,
finite numbers, booleans, or `null`. Its lowercase `sha256:` hash is computed
from deterministic canonical JSON and must equal both `payload.result_hash`
and the one successful canonical `run-stopped.data.result_hash`. The record is
omitted for failures and successful native values that cannot be represented
as strict JSON.

For record types other than `run-result`, enums and map keys are normalized to
JSON strings before retention. A `run-result.value` is never coerced; it is
rejected unless the supplied value is already strict JSON. `result` is the
bounded Dispatcher envelope returned to Lisp, so `llm-request` input/output
records contain the provider-neutral model request and normalized response, and
MCP records contain the public connector arguments and normalized result/error.
When a capability callback raises, `capability-exception` retains the exception
module name, its message at no more than 4,096 valid UTF-8 bytes, and a formatted
stacktrace at no more than 64 frames and 65,536 valid UTF-8 bytes. Independent
flags say whether either string was truncated or unavailable. Formatting does
not generically inspect or retain the raw exception struct or callback
arguments. The exception-defined message formatter does receive that struct,
however, and its authored text plus source paths in a stacktrace can expose
embedded payloads, credentials, or other sensitive data that cannot be reliably
redacted. This record therefore exists only under explicit private-inspection
authority. Exit, throw, timeout, provider-process death, and inspection-disabled
runs retain no exception record. The normalized `capability-output` and
canonical `capability-stopped` event remain the existing closed
`provider_error / exception` shape when private retention succeeds. Failure to
retain the required exception record follows the existing fail-closed
inspection contract and replaces that outcome with `inspection_sink_error`.
`evaluation-source` is emitted only for subordinate mission evaluation. Its
hash and byte count must equal the corresponding canonical
`evaluation-started` fields. After successful static analysis of that source,
`evaluation-analysis` records the sorted unique public prelude functions the
resolved program calls as exact `{"ref", "component_id"}` objects. Direct
calls and callable function references count; constants do not. Parse or
analysis failure leaves the source without an analysis record, which projects
as `prelude_calls_available?: false` rather than an empty successful result.
The analysis record is accepted before continuation state commits; a sink or
component-mapping failure fails the evaluation without committing that
continuation. `prelude-source` records carry the exact
effective source of every frozen workflow and mission component, one record
per component in frozen order, emitted by the manifest-backed builder before
execution begins. `execution-prints` is emitted for the top-level workflow
evaluation whenever it produces `println` output, whether the evaluation
succeeds or fails: `prints` is the run's bounded `println` output (at most 128
entries and 65,536 encoded bytes, matching `PtcRunner.Kernel.AnalysisSession`'s
result projection). `execution-error` is emitted only when the top-level
workflow evaluation fails with a non-empty `details` map, where `details` is
the Kernel `Error.details` map computed for that failure. Their `environment`
is always `"workflow"`, and their `evaluation_id` must match a canonical
`evaluation-started` event with `environment: "workflow"` for the same run.
When the workflow's `return` expression is directly a `kernel-eval`, private
details also contain bounded `boundary_producer` evidence: the child
`evaluation_id` when that retained successful result is exactly the workflow
boundary value, plus `complete?` indicating whether that ledger result was
intact. A syntactically transformed or independently recomputed equal value is
not treated as provenance. An empty complete list means the direct result did
not expose a valid child identity; a false completion flag forbids that
conclusion. The value itself is not duplicated in this metadata.

The input record is accepted before the callback starts. A raised callback's
exception record is accepted after the bounded provider worker has stopped and
before its normalized output is accepted. A subordinate
`evaluation-started` event is attempted before its source record is accepted,
and the source record is accepted before Lisp execution starts. The output
record is accepted after normalization and before the canonical stop event. A
missing output therefore means the attempt was interrupted; the loader does
not synthesize one. Failure to accept a required input/source record prevents
execution. Failure after an external read has completed fails the run but
cannot retroactively undo that read.

Artifact validation rejects ambiguous joins before persistence or Viewer
pinning. There may be at most one input, exception, and output for a capability ID, one
source and one subsequent analysis for an evaluation ID, and one source for an
environment/component pair.
A capability exception requires an earlier matching input, must precede any
output, and must repeat the exact environment, mission, and public capability
name. A following output must be the closed non-retryable
`provider_error / exception` envelope. An input, or input plus exception,
without an output is valid only as an interrupted retained prefix. Private
queries retain that input as `complete?: false` and do not synthesize terminal
fields. MCP provider
exchange projections still require a validated request/response pair; the
inspection sink retains each pair atomically so interruption cannot leave a
request without its response. Private
capability name and environment must match the canonical `capability-started`
event carrying the same ID, and canonical capability-start IDs must themselves
be unique. Browser indexing also refuses to overwrite a prior identity
defensively, but server validation is authoritative. There may likewise be at
most one
`execution-prints` and one `execution-error` for a given `evaluation_id`; a run
with no `println` output and no execution-phase failure emits neither.

A normal trace can prove a missing correlation only through both of its
terminal loss records: the one `events-dropped.data.counts` map and
`run-stopped.data.usage.events_dropped` must agree, and the count for
`capability-started` or `evaluation-started` must cover every distinct missing
ID of that kind. Missing evaluation IDs also retain their expected environment;
one dropped event cannot cover conflicting workflow and mission records. The
runtime emits each correlated private record only after attempting its
corresponding start event, so this typed count is authoritative evidence of
trace loss. The `events-dropped` marker and `run-stopped` must be the final two
events in that order, matching atomic EventSink finalization. The canonical
marker flags the paired inspection artifact as partial. Missing proof,
insufficient counts, duplicate canonical IDs, or an existing event whose
correlation fields disagree all fail closed.

The host enables capture independently of manifest event policy and selects a
fixed exact destination. The destination is restricted to `0600` before content
is written. Per-record and aggregate byte ceilings apply before persistence.
Inspection capture is either disabled or required/fail-closed; the inspection
sink never silently drops its own records. A trace-budget loss is different:
the canonical trace marks it explicitly, and a fully retained inspection stream
may be persisted as the trace-marked partial correlation overlay described
above. Retention belongs to the host in 0.x.

Installed defaults are 2,000,000 encoded bytes per record and 16,000,000
encoded bytes for the artifact; a host may lower them but a manifest cannot
raise or select them. Retained-size prechecks run before JSON encoding, followed
by an encoded-byte check. Post-run persistence writes an exclusive `0600`
temporary sibling and installs it with an atomic hard-link create only after
the complete artifact validates, so a failed write is not mistaken for a
complete capture. This is the smallest coherent no-clobber behavior:
`File.rename/2` can replace an existing destination, while hard-link creation
fails when the destination already exists. The temporary link is then removed.
The first increment deliberately does not append or merge inspection runs.

The first increment captures the normalized LLM request and response, exact
generated subordinate PTC-Lisp, exact effective prelude component source, and
connector capability arguments and normalized results/errors needed to
inspect a development run. It does not add transport headers, connector
credentials, session IDs, endpoints, arbitrary host terms, or the composed
workflow entry expression. Application arguments/results and prelude source
may themselves be sensitive, so the entire artifact is private. The exact
mission context that the model received is already part of the captured LLM
request. This is the exact provider-neutral `llm-request` input, not a promise
of byte-for-byte provider wire capture after adapter transformation.

The Viewer defines overlay completeness from canonical evidence. Expected LLM
calls are canonical `capability-started` events named `llm-request`; a stopped
call joins only when both private input and output exist. Expected dispatched
calls exclude reserved Kernel runtime routes (`kernel-eval`,
`kernel-check-source`, both mission
context routes, runtime usage/remaining, capability discovery, and workflow
annotation). A run cannot claim a complete overlay when it lacks a terminal
event, reports dropped events, exceeds the Viewer page budget, or lacks an
expected join. Exactly one state-aware provenance notice distinguishes a
canonical-only trace, a complete private overlay, and incomplete or failed
inspection states.

The inspection artifact is absent from TraceLog file/directory discovery and
from every primitive TraceLog query. Normal discovery explicitly rejects or omits the
`.inspection.jsonl` suffix rather than accidentally parsing it as canonical
JSONL.

A host-installed inspection snapshot composes its correlated canonical trace
through the three navigation operations. `analysis/open` includes an eligible
immutable V7 result value and canonical `result_hash`; an unknown run and a
known run without an eligible result remain distinct internally. Both encoded
and retained sizes must fit the snapshot result ceiling. Possessing a private
canonical event source, local Viewer access, or the active run does not imply
inspection authority. Calls emit ordinary bounded capability facts without
copying returned payloads into the trace.

Active-run trace self-query remains unsupported. Every trace capability call
adds events to the same sink, while pagination cursors are source-digest-bound;
the query would mutate the source it is paging. Same-run correction retains the
bounded prior program directly in provider-valid assistant/tool/result history.

Workflow annotations are host stamped, use a finite semantic vocabulary with
no caller-defined keys or string values, and cannot forge canonical events.

## Viewer and CLI sharing

`ptc_viewer`, CLI debugging, and the model-facing `analysis/*` capabilities
share the same loader, metadata derivation, filtering, ordering, pagination,
and bounded `RunAnalysis` navigation where practical.

The viewer may render richer presentations, but it is not a second canonical
query implementation or authority source. An explicit loopback-only development
mode may additionally read one exact host-selected inspection artifact through
a separate bounded loader. The browser cannot select a server-side path, and
that loader does not become a `TraceLog` operation or model capability.

Authenticated remote Viewer access and shared host authorization remain
deferred until a real host product exists. Local private inspection does not
wait for that broader work and does not change `Kernel.TraceLog` ownership.

## Failure algebra

Trace queries surface two capability-envelope kinds — `:not_found` and
`:invalid_request` (plus `:internal` for unexpected failures). The specific
condition is carried in the bounded details string. `:invalid_request` covers
`:invalid_query`, `:unsupported_version`, `:malformed_source`,
`:source_limit_exceeded`, `:result_limit_exceeded`, and `:source_changed`.

Details are bounded and sanitized. Host paths are not exposed beyond safe
grant-relative identifiers.

Inspection loading and persistence use a separate stable error set:
`:inspection_sink_error`, `:inspection_persistence_failed`,
`:invalid_inspection_source`, `:inspection_source_changed`,
`:inspection_source_limit_exceeded`, and `:inspection_run_mismatch`.
Destination preflight adds `:inspection_destination_exists`,
`:inspection_destination_unavailable`, and `:inspection_destination_unsafe`,
the last naming an ancestor with an untrusted owner or mode. Errors do
not include a record payload or host path. A completed Kernel result may be
returned as bounded context with `:inspection_persistence_failed`, matching the
existing trace-persistence distinction; persistence failure is not rewritten
as workflow failure.

## Non-goals

- ambient search over all host traces;
- arbitrary filesystem browsing;
- write/update/delete through `analysis/*`;
- a mutable authoritative run database;
- unbounded full-text search or arbitrary query expressions;
- automatic access to the current run's private events or source records;
- live prelude mutation or trace rewriting;
- benchmark/oracle/report semantics;
- provider-specific query APIs.

## Contract tests

- Append and reload canonical JSONL deterministically.
- Enforce bounded memory-sink behavior.
- Load sorted directory files under one aggregate byte cap.
- Reject path traversal and symlink escape.
- Discover runs with every required metadata field.
- Verify semantic overview/activity, internal canonical filters, ordering, and pagination.
- Verify stable cursors and source-change invalidation.
- Delete an index and rebuild identical results from canonical events.
- Reject malformed events and unsupported versions.
- Prove sanitization and absence of credentials/private source.
- Deny private sources without a distinct explicit grant.
- Share query semantics across library, capability prelude, and viewer API.
- Truncate deterministically without unbounded intermediate allocation.
- Prove mission-only trace confinement and missing-`requires` rejection.
- Capture a normal directory immutably with pre/post inventory and content
  verification, independent encoded/retained ceilings, path-redacted ownership,
  stable cursors after source mutation, and owner-driven idempotent cleanup.
- Prove snapshot-backed trace capability closures retain only the opaque token
  and return the same four canonical query projections as TraceLog.
- Prove the fixed run-analysis profile's positive and negative authority
  inventory, direct Evaluation parity, exact continuation behavior, bounded
  result/accounting projection, terminal-budget lifecycle, and path/source
  redaction.
- Saturate ordinary event count and byte capacity and retain one dropped summary
  plus exactly one terminal event through a reloadable persisted batch.
- Fault atomic publication before/during write, after sync/publication, and at
  cleanup; retries produce one complete file or a stable collision without
  partial discoverable traces or duplicate sequences.

The developer-inspection increment additionally has tests that:

- normal and private canonical turn queries never contain inspection payloads;
- evaluation source hashes and byte counts match the executed bounded source;
- the inspection loader rejects unknown/duplicate envelope or payload keys,
  invalid record types, non-monotonic sequences, and correlation IDs absent
  from the selected canonical run;
- required capability input and evaluation-source records are accepted before
  their callback/evaluation can execute, and output records contain the exact
  normalized Dispatcher envelope;
- inspection capture cannot be enabled by manifest or Lisp input;
- the private destination is restricted before its first record;
- per-record and aggregate ceilings fail closed without partial persistence;
- connector credentials, transport headers, session IDs, and endpoints are not
  added by the capture path;
- normal directory discovery omits `.inspection.jsonl` artifacts;
- the local Viewer accepts only the exact host-configured artifact and rejects
  symlinks, changed files, wrong run IDs, and oversized input; and
- querying a trace source never grants or reconstructs an inspection record.
