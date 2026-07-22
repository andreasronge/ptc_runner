# Kernel publication and boundary hardening

**Status:** triaged; first five slices implemented

**Origin:** extracted from the Java interop investigation on 2026-07-20

**Last audited:** 2026-07-22 against `origin/main` at `70b3745a`

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
| Ordinary terminal publication | Runner and standalone REPL now reserve terminal capacity, finalize atomically, and hand one frozen batch to persistence. | Complete. |
| Drop accounting and inspection | Event loss is bounded. Result, Program, and RuntimeCallable use payload-free custom `Inspect`; owner status is constant-redacted. | Complete for the identified high-value boundaries. |
| Viewer persistence | SessionTrace owns finalization and retry; TraceLog publication is synced, no-clobber, and byte-identical on retry. | Remove from the active backlog. |
| Standalone REPL ownership | ReplSession records its creator and rejects foreign evaluation or teardown before touching owner state. | Complete: sessions are process-affine and run state is bound to its configured sinks. |
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

## Completed third slice: ordinary terminal finalization

`PtcRunner.Kernel.EventSink.finalize_and_events/2` already performs atomic
terminal finalization and returns a frozen batch. Log-analysis SessionTrace
uses a two-event terminal reserve, persists the frozen batch, and retries
publication without appending another terminal event.

Ordinary Runner and standalone ReplSession previously read dropped counts,
emitted `events-dropped`, emitted `run-stopped`, and read events in separate
operations. RunBuilder then read the mutable sink independently for trace and
inspection persistence. A full normal sink could drop `run-stopped` entirely.

Normal EventSinks now reserve two terminal slots and their worst-case measured
envelopes by default. RunConfig requires that exact reserve, the sink's exact
`Limits`, enough ordinary capacity for the assembled `run-started` event, and a
payload ceiling that can retain the bounded worst-case loss summary.
The startup operation atomically claims the fresh recorder while retaining
`run-started`; a focused concurrent-reuse test demonstrated that a separate
readiness check let two runs execute against one sink, so the claim closes that
race without introducing a general producer-lease protocol. Only a successful
claimant owns shared cleanup, so a rejected runner or REPL constructor cannot
tear down provider or recorder resources used by the winner.
Runner and ReplSession close RunState before one atomic finalization call. The
EventSink owner adds the exact frozen loss snapshot to terminal usage, appends
`events-dropped` when needed and exactly one `run-stopped`, freezes the sink,
and returns both the events and loss snapshot. Later emits are contained without
mutating either. RunBuilder passes that returned event list directly to trace
and inspection persistence rather than rereading the sink.

Drop accounting retains sixteen named event-type buckets. Additional names and
invalid event types increment one `$overflow` bucket, and every counter
saturates at the unsigned 32-bit ceiling. This bounds both key cardinality and
integer growth while preserving useful common loss evidence.

Boundary tests saturate ordinary count capacity for Runner and ReplSession,
prove terminal events and returned usage agree, prove post-finalization emits
cannot change the batch, and exercise overflow accounting.

Do not add producer leases or split EventSink capabilities unless a focused
test first demonstrates that current RunState/provider cleanup permits an
event after finalization begins.

## Completed fourth slice: payload-free inspection

Derived inspection of `PtcRunner.Lisp.Result`, `PtcRunner.Kernel.Program`, and
`PtcRunner.Lisp.RuntimeCallable` reproduced direct disclosure of return and
failure values, continuation memory, prompts, messages, tool arguments and
results, child steps, program source, evaluator context, and callback identity.
Logger messages explicitly constructed from derived inspection copied the same
retained payloads.

Each owning type now has a custom `Inspect` implementation:

- Result shows only outcome, field counts, and retained memory bytes;
- Program shows only source byte size and its validated SHA-256 digest; and
- RuntimeCallable shows only its qualified label and whether it is bound.

The implementations never recursively inspect the retained payload fields.
Boundary tests place unique sentinels in success, failure, memory, prompt,
message, tool, child-result, source, and evaluator-context fields, then prove
that direct inspection and Logger messages built from it contain none of them.
The durable contract also records that direct Logger struct reports bypass
`Inspect` and are prohibited in runtime code. A RunState
status test also retains sensitive continuation values and proves the existing
constant-redacted `format_status` boundary does not enumerate them.

## Completed fifth slice: process-affine standalone REPL

Standalone ReplSession already contained run-state and event-sink handles tied
to the process that created the session. Sending the immutable session value to
another process did not transfer those owners, but while the creator remained
alive a foreign process could still evaluate against the continuation or close
and abort the creator's resources.

RunState now retains the canonical creator identity. `eval/2`, `close/1`, and
`abort/2` compare their actual caller inside that owner before consulting or
mutating any continuation, event, provider, or lifecycle state. Standalone
REPL state is non-transferable and bound to the exact configured event and
optional inspection sinks. The public session value contains only an opaque ID,
one shared creator-private lookup table, and bounded attempt counters—not an
owner PID or token. Closed lookup entries are deleted, and the empty table dies
with the creator. Continuation values and raw run-state, configuration, sink,
and provider capabilities remain inside that owner. Evaluation results use the
inert public projection while exact native memory and history stay internal;
preflight errors preserve the committed public memory view, and projection
failure rolls back before commit. A foreign caller receives the stable
`{:error, :session_owner_mismatch}` result, and the creator can continue using
and terminating the session normally. Construction also rejects a supplied
config whose event or optional inspection sink belongs to another process
before claiming either resource. The co-hosted log-analysis construction path
retains only its owner-only, one-shot transfer. Monitor-based watchdogs couple
REPL compile and evaluation sandboxes to the creator without changing its
trap-exit behavior. Each bounded worker starts its own tiny monitor-only
watchdog, so no unbounded process retains the workload closure; owner death
cancels in-flight work before the owner closes the remaining resources.

Boundary tests reproduce the former foreign evaluation and teardown, prove the
public value carries no raw resource handles or owner process identifier, prove
creator-private resource lookup and every session operation reject a foreign
process, prove a rejected evaluation commits no definition, reject foreign
configured sinks without tearing them down, reject mismatched run-state/config
construction, cancel an in-flight evaluator on owner death, and prove the
creator retains evaluation and cleanup authority. This intentionally does not
add a REPL transfer API. If a real multi-client use case appears, it requires a
separate supervised abstraction with explicit transfer, serialization, close,
abort, timeout, and owner-death behavior.

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
