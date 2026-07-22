# Kernel publication and boundary hardening

**Status:** triaged; first two slices implemented

**Origin:** extracted from the Java interop investigation on 2026-07-20

**Last audited:** 2026-07-22 against `origin/main` at `fe10efd9`

## Decision

Bounded class-aware Java interop is implemented. The implementation now has a
closed dispatch surface, native Java values, recursive Java projection, Java
projection-collision detection, and pinned conformance runners. The current
contract is documented in
[`../../java-interop.md`](../../java-interop.md).

The Java work exposed several broader boundary questions, but they should not
be treated as unfinished Java work or implemented as one hardening project.
This plan now separates:

- reproduced defects that justify small independent changes;
- infrastructure that exists but is not used by every execution path;
- product-contract decisions that need an explicit answer; and
- speculative designs that remain evidence-gated.

## Current triage

| Area | Current state | Decision |
| --- | --- | --- |
| Tool cache | Every evaluation now owns an empty, evaluation-local cache. Caller-supplied state is rejected and Results omit cache entries. | Complete. |
| Public projection | Direct and Kernel results use one collision-aware projection. Direct Elixir results preserve entries; Kernel boundaries reject ambiguity. | Complete. |
| Ordinary terminal publication | Atomic finalization, terminal reserve, and frozen batch handoff exist, but ordinary Runner and standalone REPL do not use them. | Migrate in a separate lifecycle slice. |
| Drop accounting and inspection | Drop buckets are unbounded by event-type count, and several payload-bearing structs use derived `Inspect`. | Fix with the owning boundary slices. |
| Viewer persistence | SessionTrace owns finalization and retry; TraceLog publication is synced, no-clobber, and byte-identical on retry. | Remove from the active backlog. |
| Standalone REPL ownership | A transferred ReplSession becomes closed when its creator exits. | Decide whether sessions are process-affine or transferable before changing ownership. |
| Oracle supervision | The current subprocess-per-run harness has timeout, output, and temporary-directory bounds. | Keep the reusable service deferred until a leak or throughput problem is measured. |

## Completed by Java interop

The following concerns from the original investigation are implemented and do
not need another generic mechanism merely because Java values exist:

- valid Java values remain native only at native and continuation boundaries;
- public and Kernel boundaries project Java values to inert values;
- direct tool arguments are projected before the cache key is calculated, so
  the key describes the value observed by the callback;
- newly returned tool results reject Java callables and other unsupported Java
  values;
- recursive Java projection detects map and set collisions; and
- the JVM and Babashka conformance runners enforce source, time, output, and
  result bounds.

These guarantees are Java-specific. They do not validate every possible BEAM
term or make the generic publication paths authoritative.

## Completed first slice: imported tool-cache boundary

### Defects removed

The former imported-cache path had two reproduced defects:

1. `PtcRunner.Lisp.run/2` accepted any map as `:tool_cache`. A matching malformed
   entry was read through `cached.result` and failed later with a `KeyError`
   instead of a stable cache-boundary error.
2. A fresh tool result containing a Java callable was rejected by the
   `:tool_result` projection, while the same value in a matching imported cache
   entry was accepted and returned as a successful hit.

The `:tool_cache` option was not documented by `PtcRunner.Lisp.run/2`, and the
repository had no production caller outside the Lisp evaluator and its tests.
Kernel and standalone REPL evaluations already started with an empty cache.
Cross-run reuse therefore had cost and authority but no established product
contract.

The implementation removed imported cache state without designing a public
cache protocol.

### Implemented contract

The first slice established these invariants:

- every top-level direct, Kernel, and standalone REPL evaluation starts with an
  empty tool cache;
- only a successful result projected through the current `:tool_result`
  boundary can create an entry;
- entries live for one evaluation; sequential and higher-order paths see
  earlier entries, while parallel worker entries merge in input order after
  the parallel operation;
- private and non-cacheable tools never create or consume entries;
- cache identity continues to derive from prepared callback-visible arguments;
  and
- public and native `PtcRunner.Lisp.Result` values do not expose cache entries.

Top-level `:tool_cache` input raises `ArgumentError` before telemetry or
evaluation rather than being silently ignored. No compatibility shim retains
the old map shape.

### Implementation

The slice:

1. added a regression test showing that caller-supplied cache state could turn
   a rejected Java result into a successful hit;
2. rejects top-level `:tool_cache` input before evaluation;
3. creates an empty cache in each evaluator context;
4. removes the cache field and payloads from `PtcRunner.Lisp.Result`;
5. retains within-evaluation cache behavior for sequential,
   higher-order, and parallel calls; and
6. documents the evaluation-local lifetime in `PtcRunner.Lisp`,
   `PtcRunner.Lisp.Result`, and the Kernel maintainer guide.

### Non-goals

Do not include these in the first slice:

- a reusable cross-run cache API;
- opaque cache records, schema versions, or tool generations;
- a cache owner process;
- Kernel JSON-tool caching;
- EventSink or trace finalization changes;
- a universal BEAM-value boundary algebra;
- option-list preflight for every public API;
- standalone REPL lifecycle ownership; or
- a reusable oracle worker service.

### Verification

Focused tests prove:

- top-level `:tool_cache` input is rejected and never invokes the provider;
- a fresh Java callable result remains rejected with no imported-hit bypass;
- repeated valid calls within one evaluation reuse the result without invoking
  the provider again;
- separate evaluations invoke the provider separately;
- private and non-cacheable tools do not cache;
- callback-visible key normalization remains unchanged;
- parallel cache merges preserve deterministic existing precedence; and
- public and native results have no cache field.

The owning module documentation is updated with the implementation. Both
`mix precommit` and `mix prepush` pass on the completed slice.

If a real cross-run reuse requirement appears later, design it as a separate
public contract with schema versioning, explicit tool generation, result
validation, bounds, and redacted inspection. Do not reopen the boundary by
accepting the old plain-map representation.

## Completed second slice: collision-safe public projection

Java projection was already collision-aware, and
`PtcRunner.Lisp.externalize_value/1` preserved distinct generic map keys with
inert wrappers. The former public `PtcRunner.Lisp.Result` path nevertheless
applied another recursive projector that could silently collapse two different
function keys to one `"#fn[...]"` key.

A reproduced example is:

```clojure
{(fn [x] x) 1
 (fn [x] (+ x 1)) 2}
```

The old public result contained only `%{"#fn[...]" => 2}`.

Direct Results, subordinate Kernel results, and workflow terminal results now
use the same recursive Lisp-value projector after boundary-specific Java
projection. The duplicate Result and Kernel walkers were removed. Direct
Elixir observations, including log analysis, retain every colliding map key and
set member through inert collision wrappers. JSON-facing runtime-tool and
workflow boundaries reject both equal projected values and distinct values
with the same strict JSON representation using the stable
`:public_projection_collision` reason before continuation commit or workflow
publication.

Boundary tests cover maps and sets containing distinct callables as well as a
callable beside its literal display string. The implementation does not add
generic validation for every host-supplied BEAM term.

## Third slice: ordinary terminal finalization

`PtcRunner.Kernel.EventSink.finalize_and_events/3` already performs atomic
terminal finalization and returns a frozen batch. Log-analysis SessionTrace
uses a two-event terminal reserve, persists the frozen batch, and retries
publication without appending another terminal event.

Ordinary Runner and standalone ReplSession still read dropped counts, emit
`events-dropped`, emit `run-stopped`, and read events in separate operations.
RunBuilder then reads the mutable sink independently for trace and inspection
persistence. Existing tests explicitly allow `run-stopped` to be dropped by a
full normal sink.

For a system that treats logs as future improvement evidence, ordinary traces
should have the same terminal integrity as Viewer traces. A separate slice
should:

- reserve terminal capacity for ordinary normal sinks;
- give Runner and standalone REPL one terminal finalization operation;
- return one frozen batch for trace and inspection persistence;
- compute public event-loss usage from that same terminal state; and
- cap drop accounting to fixed event-type buckets plus an overflow count.

Do not add producer leases or split EventSink capabilities unless a focused
test first demonstrates that current RunState/provider cleanup permits an
event after finalization begins.

## Inspection and redaction follow-up

Review payload-bearing structs when their owning boundary changes. The current
high-value candidates are:

- `PtcRunner.Lisp.Result`, which can retain memory, tool calls, prompts,
  messages, and child steps;
- `PtcRunner.Kernel.Program`, which retains source; and
- `PtcRunner.Lisp.RuntimeCallable`, which can retain evaluator context and a
  function.

Custom `Inspect` implementations should show safe identity, counts, and byte
metadata without enumerating payloads. Tests should use unique sentinels in
success, failure, memory, prompt, tool, and child-result fields. Logger and
`format_status` paths must not expose those sentinels.

## Product decision: standalone REPL ownership

Standalone ReplSession currently contains handles owned by the process that
created the session. Sending the immutable session value to another process
does not transfer ownership; when the creator exits, later evaluation returns
`:session_closed`.

Choose one contract before implementing a new lifecycle process:

- **Process-affine session:** document the creator/owner constraint and reject
  use from another process with a stable error.
- **Transferable session:** add a supervised lifecycle owner independent of the
  creator and define transfer, close, abort, timeout, and owner-death behavior.

Do not infer the larger transferable design merely because the session is an
Elixir struct.

## Deferred investigations

The following ideas still require a reproduced defect or measured limit before
they become implementation work:

- bounded preflight shared by selected option-list APIs;
- named depth/node/byte/deadline episodes for generic host values;
- one universal public/private/JSON boundary algebra;
- a reusable cross-run tool-cache protocol;
- producer leases and split EventSink capabilities;
- generated minimum-capacity proofs for complete failure envelopes; and
- a reusable multi-process conformance worker and OS-process reaper.

For the Java oracle, first add focused timeout and child-cleanup tests. Build a
long-lived service only if those tests expose leaks or measured execution time
shows that subprocess startup is a material bottleneck.

## Completed work to remove from future planning

Viewer/session trace work already provides:

- SessionTrace-owned finalization;
- terminal capacity reservation;
- immutable terminal batch retention;
- owner-death cleanup;
- persistence retry from the same batch;
- encode-before-open publication;
- exclusive same-directory temporary files;
- synced no-clobber publication;
- byte-identical retry success; and
- fault coverage before, during, and after publication.

Do not propose another Viewer persistence redesign without a new reproduced
defect. One smaller API question remains: public abort reasons currently accept
any atom and may need a closed enum if callers outside the trusted frontend are
supported.

## Decision gates for later slices

Before promoting another item from this plan:

- identify every current production entry and exit path;
- reproduce the bug, race, disclosure, leak, drift, or unbounded state;
- state the smallest invariant that fixes it;
- choose one authoritative representation or owner;
- migrate all paths in one vertically complete slice;
- delete the replaced mechanism instead of adding a compatibility layer;
- add boundary-level tests for success and relevant failures; and
- move the implemented contract into module documentation, a guide, or a
  retained specification before deleting the completed plan section.
