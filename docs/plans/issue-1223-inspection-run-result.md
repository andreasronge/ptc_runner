# Private inspection run results (#1223)

Branch: `codex/issue-1223-inspection-result`.

## Problem and observable change

`inspection-analysis-v2` can correlate exact model exchanges, capability
payloads, generated sources, effective preludes, provider exchanges, prints,
and execution errors with a completed canonical run. It cannot read the
successful terminal value that those operations produced. The value exists in
stdout, a command envelope, or a caller-selected result artifact, while the
canonical `run-stopped` event retains only its deterministic `result_hash`.
Consequently an analysis program can critique process but cannot compare that
process with the answer without a harness joining a third artifact out of band.

This slice advances private inspection writers to schema V5. A successful,
strict-JSON Kernel result with a canonical result hash adds exactly one
`run-result` record to the already-private inspection artifact. Persistence
recomputes its deterministic JSON hash and requires it to equal the same run's
canonical `run-stopped.data.result_hash`. `inspection-analysis-v2` exposes the
validated record through `(inspection/result run-id)`, and `log/run` projects
the safe canonical `result_hash` so an analysis can verify the join directly.

`run-result` means the Kernel's successful terminal value. It is not evidence
that a caller-selected `--output` destination, command envelope, or any other
later publication succeeded. Artifact publication remains a separate command
boundary with its existing ordering and failure taxonomy.

The production cutover is `RunBuilder`'s current inspection writer, which
starts V5 sinks. V1 through V4 artifacts remain readable. No compatibility
writer, synthesized result for legacy artifacts, or fallback filesystem read
is added.

## Explicit non-goals

- Do not put exact values in canonical traces, analysis traces, logs,
  diagnostics, process status, or command errors.
- Do not add result-file, envelope, or filesystem authority to an analysis
  profile.
- Do not create a result snapshot owner or a third profile resource.
- Do not claim that a result artifact was published merely because Kernel
  execution returned a value.
- Do not capture failed-run error details as a synthetic result; existing
  execution-error inspection remains authoritative for failures.
- Do not make native non-JSON embedding results inspectable, even when the
  deterministic encoder can hash their runtime structs. Hash presence is not
  proof that a value satisfies the strict JSON boundary.
- Do not add a deprecated V4 write path or alter historical V1-V4 vocabularies.

## Record and query contract

V5 adds one record type:

```json
{
  "schema_version": 5,
  "run_id": "cmd-...",
  "trace_id": "cmd-...",
  "sequence": 12,
  "timestamp": "...Z",
  "record_type": "run-result",
  "correlation": {},
  "payload": {
    "result_hash": "sha256:...",
    "value": {}
  }
}
```

The value is the `Result` value itself after an independent `JSONValue.value?/1`
check; hash presence alone is not an eligibility check, and no second projection
or coercion is permitted. The sink admits exactly one `run-result`, requires an
empty correlation object, a canonical `sha256:` digest, and a strict JSON value.
Existing per-record (2 MB), total-artifact (16 MB), retained-size, and
structural-depth ceilings apply unchanged. The Kernel's 1 MB terminal retained
and external-term limits do not imply that escape-heavy JSON will fit the 2 MB
encoded inspection record. Such a record fails the inspection sink closed,
using the existing command failure and result-withholding behavior.

Standalone artifact loading requires all of:

- exactly zero or one `run-result` record;
- a canonical `result_hash` of the exact supported form;
- deterministic JSON encoding of `payload.value`; and
- equality between the recomputed digest and the private record digest.

Persistence, which receives canonical events, and later snapshot capture,
which binds loaded inspection records to a `TraceSnapshot`, additionally
require a matching `run-stopped` event for the same run and trace, canonical
outcome `ok`, and equality between the recomputed/private digest and the
canonical digest. `InspectionArtifact.load/2` does not claim a cross-artifact
guarantee when no canonical events are available.

An absent result remains valid for legacy schemas, failed runs, native
non-JSON results, and traces whose successful result was not hashable. A V5
record that is present but mismatched fails closed; event-loss allowances do
not excuse a result mismatch because `run-stopped` is terminal-reserved.

`(inspection/result run-id)` takes no cursor because at most one item exists.
It returns the validated record projection plus the inspection snapshot hash:

```clojure
{"run_id" "cmd-..."
 "trace_id" "cmd-..."
 "sequence" 12
 "timestamp" "...Z"
 "result_hash" "sha256:..."
 "value" {...}
 "snapshot_hash" "sha256:..."}
```

Unknown run IDs and known runs without an inspectable result have distinct
internal errors so capability diagnostics do not falsely call an absent result
an absent run. The exact value remains subject to the existing private-profile
result limit. The singular query checks both the final JSON-encoded projection
and its retained size, including `snapshot_hash`, before crossing the provider
boundary. A value that fails either check returns the inspection-specific
`result_limit_exceeded` diagnostic instead of falling through to the
Dispatcher's generic `provider_result_limit`; this slice does not invent
chunked JSON traversal.

`log/run` adds `result_hash`, returning the canonical digest or `nil` for an
incomplete, failed, legacy, or non-hashable run. For every supported trace
schema, a present hash must be a lowercase 64-hex `sha256:` digest and may occur
only when `run-stopped.outcome` is `ok`; otherwise the trace is malformed.
Unsupported trace schemas remain `unsupported_version` regardless of their
payload. It never reads private inspection data or a result artifact.

## Capture and ownership

No new owner or deadline is introduced.

| Resource | Creator | Fixed owner | Authorized users | Closer |
| --- | --- | --- | --- | --- |
| Event sink | `RunBuilder` | execution-session owner | Runner emission/finalization | execution-session owner |
| Inspection sink | `RunBuilder` | execution-session owner | runtime instrumentation and `ExecutionOutcome.capture/6` | execution-session owner |
| Sealed execution outcome | `ExecutionOutcome.capture/6` | opaque value held by command owner | `ArtifactPublisher` with matching publication authority | consumed with authority cleanup |
| Inspection artifact | `ArtifactPublisher` | immutable file | later `InspectionSnapshot` capture | filesystem owner |
| Inspection snapshot | `InspectionAnalysisProfile.capture/2` | analysis session | installed read-only inspection capabilities | analysis session |

The result record is emitted in `ExecutionOutcome.capture/6`, after Runner has
finalized canonical events and provider cleanup has selected the terminal
result, but before retained inspection records are copied and the sink is
stopped. The capture reads the canonical hash from the sealed terminal batch;
it does not recompute or trust a caller-supplied identity. Older sink versions
skip the new record exactly as older sinks skip later diagnostic vocabulary.

If V5 result emission fails validation or a sink bound, inspection capture is
marked failed. `ArtifactPublisher` then preserves the current observation-first
ordering: inspection publication fails and the result destination is withheld.
The already-finalized canonical run still truthfully records execution success;
the command reports the inspection publication/capture failure separately.

## Failure matrix

| Case | Required behavior |
| --- | --- |
| Successful JSON result, healthy V5 sink | Retain one result record; persist it; query returns exact value and matching hash. |
| Successful result, no inspection requested | No extra work and unchanged result/publication behavior. |
| Successful native non-JSON result | No record after the independent strict-JSON check, even if deterministic encoding produced a canonical hash; Kernel result remains unchanged. |
| Workflow or provider-cleanup failure | No result record; existing execution-error/process evidence remains available. |
| Result-contract rejection | Retain the successful Kernel terminal value for private diagnosis; query documentation states that it is not publication proof. |
| Inspection sink already failed | Outcome carries `inspection_sink_error`; no result publication ordering changes. |
| Escape-heavy result or other record exceeds a sink bound | Sink fails closed; command withholds later result publication and reports inspection failure. |
| Private value/hash mismatch | Standalone artifact loading rejects the source. |
| Canonical/private hash mismatch or missing successful terminal event | Persistence or snapshot capture rejects the whole source; event-loss allowance cannot admit it. |
| Invalid canonical hash or hash on failed run | Trace loading rejects the source as malformed; unsupported trace schemas remain unsupported. |
| Singular result exceeds JSON or retained query limit | Capability returns the inspection-specific result-limit diagnostic before Dispatcher applies its generic provider limit. |
| Caller death or execution-owner death | Existing owner monitors stop the sink; no partial artifact is published. |
| Snapshot capture worker death/deadline/heap failure | Existing bounded snapshot startup fails without publishing a partial catalog. |
| Analysis-session owner death | Existing snapshot monitor closes retained private state. |
| Ambiguous sink call timeout | No new timeout is added; the synchronous owner call has the existing GenServer failure behavior and cannot be retried as a second record. |

## Implementation slices

1. **Failing boundary tests.** Add an integration test that runs a successful
   inspected workflow, proves `log/run.result_hash` matches the canonical
   event, and expects `(inspection/result run-id)` to return the exact terminal
   value. Add focused sink/artifact tests for V5 shape, uniqueness, hash
   correlation, tampering, absent results, V4 compatibility, and sink limits.
   Cover a native symbol-reference value that is hashable but not strict JSON,
   an escape-heavy command result that breaches the encoded record limit, and
   the singular query limit through the installed analysis capability.
2. **V5 capture and validation.** Extend `InspectionRecordTypes`,
   `InspectionSink`, and `InspectionArtifact`; make `RunBuilder` write V5; emit
   the result from `ExecutionOutcome.capture/6` before copying records. Gate it
   independently with `JSONValue.value?/1`, and reuse deterministic JSON
   encoding and canonical terminal hashes rather than defining a second value
   identity.
3. **Private query surface.** Add the singular result operation to
   `InspectionQuery`, `InspectionSnapshot`, `InspectionCapability`, and
   `InspectionAnalysisProfile`; add `(inspection/result run-id)` to
   `inspection.core`; do not add a pointless paginated `all-result` wrapper.
4. **Safe trace hash projection.** Add `result_hash` to `TraceLog` run metadata
   and its tests/specification so public trace analysis can verify the private
   join without receiving the value. Validate hash syntax and successful-run
   placement during trace loading, including malformed and unsupported-version
   cases.
5. **Durable documentation and cleanup.** Update module docs,
   `docs/trace-log-contract.md`, `docs/guides/kernel-repl.md`, and
   `docs/guides/kernel-maintainer.md`. Regenerate shipped prelude artifacts if
   required by the normal generator, run documentation and repository gates,
   and delete this completed plan after its durable contracts have moved to
   retained documentation.

## Verification and review

- Focused tests for `ExecutionOutcome`, inspection sink/artifact/snapshot,
  analysis profile, trace capability, and command integration.
- `mix format --check-formatted` and compile with warnings as errors before
  independent implementation review.
- `MIX_ENV=dev mix docs --warnings-as-errors` after documentation changes.
- `mix precommit` on the final reviewed tree.
- At most two independent plan-review invocations and at most three
  implementation-review invocations. Follow-ups resume the named session;
  byte-identical trees are not cold-reviewed.
- The draft PR body lists every unresolved review item, or explicitly states
  that none remain.
