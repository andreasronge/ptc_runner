# TraceLog and Log Prelude — V1 Contract

**Status:** proposed retained product contract. Complements
[`kernel-contract.md`](kernel-contract.md) and
[`private-experiment-transcripts.md`](private-experiment-transcripts.md).

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

Normal trace sinks sanitize before persistence. Exact private transcript sinks
follow [`private-experiment-transcripts.md`](private-experiment-transcripts.md).

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
- keeps private transcript access separate and explicitly granted;
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

## Events and private transcripts

The generic Kernel emits lifecycle, subordinate-evaluation, capability,
resource, annotation, and terminal facts. Providers may attach safe typed
metadata. An LLM adapter can therefore support model request/response
transcripts without making Kernel understand LLMs.

Private capture may retain exact safe model-visible requests, responses,
programs, and prelude source under explicit local-only controls. Those fields do
not appear in normal queries without a distinct private source grant.

Workflow annotations are host stamped and cannot forge canonical events.

## Viewer and CLI sharing

`ptc_viewer`, CLI debugging, and the model-facing `log/` capability share the
same loader, metadata derivation, filtering, ordering, and pagination code where
practical.

The viewer may render richer presentations, but it is not a second query
implementation or authority source. A future Viewer Lab remains a client of the
same run and TraceLog contracts.

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

## V1 non-goals

- ambient search over all host traces;
- arbitrary filesystem browsing;
- write/update/delete through `log/`;
- a mutable authoritative run database;
- unbounded full-text search or arbitrary query expressions;
- automatic access to the current run's private transcript;
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
