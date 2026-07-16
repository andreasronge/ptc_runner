# TraceLog and Log Prelude — V1 Contract

**Status:** implemented retained product contract, including the local 0.x
inspection increment. Complements the
[Kernel maintainer guide](../../guides/kernel-maintainer.md) and
`PtcRunner.Kernel.TraceLog` module documentation.

## Purpose and boundary

TraceLog preserves bounded, queryable facts about Kernel runs for humans,
automated diagnostics, and explicitly authorized PTC-Lisp workflows.

```text
Kernel and capability providers
  emit canonical bounded events

TraceLog
  stores, sanitizes, loads, indexes, filters, and bounds event queries

Consumers
  ptc_viewer, CLI/debug tools, and a swappable log/ capability prelude
```

Kernel does not know how traces are stored or queried. TraceLog does not control
workflow execution. Consumers do not invent competing event representations.

## Observability planes

PtcRunner keeps four observability concerns separate:

- Elixir `Logger`, backed by OTP `:logger`, reports sparse operational
  diagnostics such as unexpected host failures and degraded optional services.
- `:telemetry` reports low-cardinality measurements for embedders and host
  monitoring. It is not an event store or an authorization boundary.
- `Kernel.EventSink` and `Kernel.TraceLog` own the canonical bounded run event
  journal consumed by `ptc_viewer`, CLI diagnostics, and `log/` capabilities.
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
an explicitly enabled inspection artifact. Erlang VM tracing (`:erlang.trace`,
`:dbg`, or `:sys.trace`) is an operator debugging facility, not a product trace
source.

After the Phase 0 cleanup, the existing Lisp execution Telemetry prefix remains
`[:ptc_runner, :lisp, :execute]`. Its closed `caller` values are `:direct`,
`:kernel`, and `:repl`; the obsolete `profile` tag is removed. Stop metadata
adds the semantic `outcome` (`:ok` or `:error`) while measurements retain
duration, program/result byte counts, and print count. Exception telemetry may
identify the exception class but does not attach the raw reason, stacktrace,
source, arguments, or result. These events are metrics for embedders, not the
source used to reconstruct a run.

The Viewer must have one canonical event model. Its temporary legacy raw-JSONL
routes and `trace.start`/`run.start` parser are removed before the inspection
loader lands, once no supported producer remains. The inspection loader is not
a replacement legacy trace schema; it joins private records to canonical IDs.

## Canonical authority

The append-only canonical event stream is authoritative. Derived run metadata,
counters, indexes, and viewer projections must be rebuildable from it.

An index may accelerate discovery and pagination, but it:

- is never the sole copy of run facts;
- records the source identity/version it indexes;
- is invalidated or rebuilt when its source changes;
- does not silently merge unrelated trace sources;
- cannot grant access beyond the underlying source grant.

Do not maintain a second authoritative session/run database in V1.

## Storage sources

V1 supports:

- append-only JSONL files;
- explicitly granted directories containing JSONL files;
- a bounded in-memory sink for REPL, tests, and short-lived runs.

JSONL files are written in canonical sequence order. Directory loading is
deterministic: discover supported files, normalize paths, sort them, then load
in sorted order under one aggregate byte cap.

Normal trace sinks sanitize before persistence. Private canonical event sinks
use the separate fail-closed policy specified by the event-sink section of the
`PtcRunner.Kernel.EventSink` module documentation, but retain the same event
vocabulary rather than capturing exact payloads or source.

Malformed or unsupported canonical events fail closed by default. A debugging
mode may report bounded per-file errors, but it never silently reinterprets
malformed data as valid runs.

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

The `log/` prelude contains no authority. It requires host trace-query
capabilities whose source grant provides authority. Missing requirements fail
before workflow code runs.

Trace-query capabilities belong in the mission environment when subordinate
programs may inspect traces. Workflow and mission environments never inherit
each other's trace grants.

## Run identity

Every run has a stable run ID and trace ID. Events carry a monotonic sequence
and timestamp, plus evaluation/capability IDs where applicable.

Grouping does not depend only on filenames. Duplicate events may be
deduplicated only by a documented stable identity such as `{trace_id, seq}`.

Mixed schema versions are upgraded through an explicit bounded reader or
rejected with a stable unsupported-version error. Query code does not guess
missing identity fields.

## Required run metadata

`log/runs` and `log/run` expose bounded sanitized metadata sufficient to select
a run without loading its turns:

- run ID and trace ID;
- start and stop timestamps;
- status and terminal reason when present;
- workflow/agent name when supplied;
- model and provider identifiers when recorded by a provider;
- subordinate-evaluation count;
- workflow and mission capability-call counts;
- LLM-call summary derived from named `llm/request` events when applicable;
- error count and duration summary;
- tags and caller-supplied safe labels;
- effective workflow and mission prelude component IDs and hashes;
- frozen mission-inventory hash and byte count when an inventory was rendered;
- safe connector snapshots containing public names, effects, schema hashes, and
  snapshot hashes, but no endpoint or session data;
- completeness and truncation indicators;
- schema version;
- whether the source is sanitized normal data or an explicitly granted private
  source.

Normal metadata excludes credentials, headers, environment values, callback
terms, arbitrary provider metadata, exact private prelude source, and unbounded
messages/tool results. Absent optional facts remain absent or `nil`.

## Query contract

The shipped default prelude exposes:

```clojure
(log/runs options)
(log/run run-id)
(log/turns run-id options)
(log/counters options)
```

Examples:

```clojure
(log/runs {:status :error :tags {:stage "editor"} :limit 20})
(log/run "run-id")
(log/turns "run-id" {:status :error :limit 20})
(log/counters {:run "run-id"})
```

### `log/runs`

Discovers runs in the granted source. V1 filters are limited to run/trace ID,
status, bounded exact-match tags, workflow/agent name, model/provider when
present, timestamp range, limit, and cursor.

Default ordering is deterministic: newest start timestamp first, with run ID as
a stable tie-breaker.

### `log/run`

Returns metadata for one source-visible run or a uniform not-found/denied error.
It does not return all turns implicitly.

### `log/turns`

Returns bounded canonical turn/subordinate-evaluation projections for one run.
V1 filters include status, evaluation/turn ID, capability name, limit, and
cursor. Ordering is ascending canonical sequence.

### `log/counters`

Returns bounded aggregate counters using the same source and filters as run
discovery. Counters may include run status, errors, evaluations, and
workflow/mission capability calls by bounded name. They are reproducible from
the selected canonical events.

## Pagination, ordering, and bounds

Every collection query has:

- a conservative default and hard maximum limit;
- a deterministic opaque cursor;
- deterministic ordering and tie-breakers;
- a maximum encoded result size;
- truncation and omitted-count metadata;
- one aggregate source-read byte cap;
- bounded filter/tag/name lengths and counts.

A cursor is bound to the source identity, query operation, and normalized
filters that produced it. Changing filters or reusing a cursor for another
operation fails as an invalid query; changing the source fails as
`source-changed`. The caller may reduce or increase the page limit within the
hard maximum without changing the selected result set.

If a page would exceed the result ceiling, return the largest valid prefix plus
explicit truncation/next-cursor metadata, or a stable bounded error. Never build
an unbounded result and truncate only after allocation.

Preview fields are bounded independently. Arguments/results, messages, prints,
memory diffs, and program source follow their own projection ceilings.

## Capabilities and swappable preludes

Host query capabilities follow the standard Kernel envelope and may be named:

- `trace-list-runs`;
- `trace-get-run`;
- `trace-list-turns`;
- `trace-counters`.

The default `log.core` prelude requires them and provides the regular Lisp API.
Higher-level preludes may compose it:

```text
log.analysis
  depends: log.core
  requires: trace-counters
```

Preludes may change ergonomics, projections, defaults, or analysis policy. They
cannot expand the source grant, bypass bounds/sanitization, or acquire private
trace access.

## Events and private data

The generic Kernel emits lifecycle, subordinate-evaluation, capability,
resource, annotation, and terminal facts. Providers may attach safe typed
metadata without making Kernel understand provider-specific transcripts.

The implemented private event policy stores the same canonical event
vocabulary as the normal policy. It changes sink failure behavior, file
permissions, and discovery; it does not capture prompts, responses, capability
payloads, generated programs, or prelude source. Private JSONL destinations are
restricted to owner read/write permissions before any event payload is
appended. They use the reserved `.private.jsonl` suffix, and normal
file/directory sources and Viewer discovery reject or omit that suffix.

### Implemented 0.x developer-inspection increment

Sanitized subordinate `evaluation-started` data adds:

- `source_hash` — lower-case SHA-256 hex over the exact UTF-8 source bytes passed
  to `Lisp.run_native/2`;
- `source_bytes` — `byte_size(source)` over those same bytes; and
- `program_kind: "ptc-lisp"` alongside the existing
  `environment: "mission"` and `evaluation_id`.

It must not contain exact source. `trace-list-turns` returns canonical event
data, so embedding source in a supposedly private event would collapse source
authorization into the ordinary turns query.

Optional sensitive development capture uses a separate private inspection
record stream, not a canonical event. Every `.inspection.jsonl` line is one
JSON object with this exact envelope:

```json
{
  "schema_version": 1,
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
artifact. The timestamp is UTC ISO 8601. `correlation` contains exactly one of
`capability_id` or `evaluation_id`, and that value must occur in the canonical
trace for the same run. V1 record types and payloads are:

| Record type | Correlation | Exact payload fields |
| --- | --- | --- |
| `capability-input` | `capability_id` | `environment`, `name`, `arguments` |
| `capability-output` | `capability_id` | `environment`, `name`, `result` |
| `evaluation-source` | `evaluation_id` | `environment`, `program_kind`, `source`, `source_hash`, `source_bytes` |

Enums and map keys are normalized to JSON strings before retention. `result` is
the bounded Dispatcher envelope returned to Lisp, so `llm-request` input/output
records contain the provider-neutral model request and normalized response, and
MCP records contain the public connector arguments and normalized result/error.
`evaluation-source` is emitted only for subordinate mission evaluation in this
increment. Its hash and byte count must equal the corresponding canonical
`evaluation-started` fields.

The input record is accepted before the callback starts, and the source record
is accepted before evaluation starts. The output record is accepted after
normalization and before the canonical stop event. A missing output therefore
means the attempt was interrupted; the loader does not synthesize one. Failure
to accept a required input/source record prevents execution. Failure after an
external read has completed fails the run but cannot retroactively undo that
read.

The host enables capture independently of manifest event policy and selects a
fixed exact destination. The destination is restricted to `0600` before content
is written. Per-record and aggregate byte ceilings apply before persistence.
Capture is either disabled or required/fail-closed; there is no silent partial-
capture mode. Retention belongs to the host in 0.x.

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
generated subordinate PTC-Lisp, and connector capability arguments and
normalized results/errors needed to inspect a development run. It does not add
transport headers, connector credentials, session IDs, endpoints, arbitrary
host terms, complete workflow entry source, or exact effective prelude source.
Application arguments/results may themselves be sensitive, so the entire
artifact is private. The exact mission inventory that the model received is
already part of the captured LLM request.

The inspection artifact is absent from TraceLog file/directory discovery and
from every `log/` query. Normal discovery explicitly rejects or omits the
`.inspection.jsonl` suffix rather than accidentally parsing it as canonical
JSONL.

A later host-installed capability may read one completed immutable inspection
record by run and record ID under separate input, source, and result ceilings.
Possessing `trace-list-turns`, a private canonical event source, local Viewer
access, or the active run does not imply this capability. Calls emit ordinary
bounded capability facts without copying returned payloads into the trace.

Active-run trace self-query remains unsupported. Every trace capability call
adds events to the same sink, while pagination cursors are source-digest-bound;
the query would mutate the source it is paging. Same-run correction retains the
bounded prior program directly in provider-valid assistant/tool/result history.

Workflow annotations are host stamped and cannot forge canonical events.

## Viewer and CLI sharing

`ptc_viewer`, CLI debugging, and the model-facing `log/` capability share the
same loader, metadata derivation, filtering, ordering, and pagination code where
practical.

The viewer may render richer presentations, but it is not a second canonical
query implementation or authority source. An explicit loopback-only development
mode may additionally read one exact host-selected inspection artifact through
a separate bounded loader. The browser cannot select a server-side path, and
that loader does not become a `TraceLog` operation or model capability.

The non-normative
[`host-access-and-prelude-workspaces.md`](host-access-and-prelude-workspaces.md)
notes defer authenticated remote Viewer access and shared host authorization
until a real host product exists. Local private inspection does not wait for
that broader work and does not change `Kernel.TraceLog` ownership.

## Failure algebra

Trace failures use the standard capability envelope with stable kinds such as:

- `:not-found`;
- `:denied`;
- `:invalid-query`;
- `:unsupported-version`;
- `:malformed-source`;
- `:source-limit-exceeded`;
- `:result-limit-exceeded`;
- `:source-changed`.

Details are bounded and sanitized. Host paths are not exposed beyond safe
grant-relative identifiers.

Inspection loading and persistence use a separate stable error set:
`:inspection_sink_error`, `:inspection_persistence_failed`,
`:invalid_inspection_source`, `:inspection_source_changed`,
`:inspection_source_limit_exceeded`, and `:inspection_run_mismatch`. Errors do
not include a record payload or host path. A completed Kernel result may be
returned as bounded context with `:inspection_persistence_failed`, matching the
existing trace-persistence distinction; persistence failure is not rewritten
as workflow failure.

## V1 non-goals

- ambient search over all host traces;
- arbitrary filesystem browsing;
- write/update/delete through `log/`;
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
- Verify `log/run`, turn filters, counters, ordering, and pagination.
- Verify stable cursors and source-change invalidation.
- Delete an index and rebuild identical results from canonical events.
- Reject malformed events and unsupported versions.
- Prove sanitization and absence of credentials/private source.
- Deny private sources without a distinct explicit grant.
- Share query semantics across library, capability prelude, and viewer API.
- Truncate deterministically without unbounded intermediate allocation.
- Prove mission-only trace confinement and missing-`requires` rejection.

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
