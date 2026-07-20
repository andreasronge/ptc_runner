# Kernel publication and boundary hardening

**Status:** future investigation

**Origin:** extracted from the Java interop investigation on 2026-07-20

## Summary

This document retains cross-cutting hardening ideas discovered while reviewing
Java interop. They are not required to implement bounded class-aware Java
interop and must not be bundled into that migration without a separately
approved objective.

The focused interop work remains in
[`../lisp-kernel/bounded-class-aware-java-interop.md`](../lisp-kernel/bounded-class-aware-java-interop.md).

The ideas fall into four independent areas:

1. generic host-value ingress, validation, projection, and redaction;
2. tool result and cache identity hardening;
3. Kernel event publication, terminal finalization, and trace persistence; and
4. long-lived REPL/Viewer lifecycle ownership and reusable oracle-process
   supervision.

Each area needs its own current-code audit, problem statement, implementation
plan, and acceptance gate. This document is a research backlog rather than one
large implementation proposal.

## Why this is separate from Java interop

Java tagged values make existing boundary behavior easier to inspect, but they
do not create most of the generic issues listed here. The Java plan needs only
to retain valid Java values at native boundaries and project or reject them at
existing public boundaries.

It does not require:

- a new EventSink capability protocol;
- changing how all runs finalize and persist traces;
- a new REPL owner process;
- changing Viewer close/retry semantics;
- replacing the complete tool cache representation;
- validating every possible BEAM term through one global algebra;
- changing all telemetry transactions; or
- a reusable multi-process conformance worker service.

Combining those projects would make the Java migration difficult to review,
test, land, or revert. It would also make unrelated Kernel behavior a blocker
for fixing known Java semantics.

## Area A: generic host ingress and public projection

### Observed concerns

Public Lisp APIs accept option lists and nested host values through context,
memory, history, tools, Prelude artifacts, evaluator entry points, and caches.
Several consumers recursively traverse those values for validation,
externalization, formatting, error reporting, retained-size accounting, or
static analysis.

Potential generic risks include:

- improper or very long keyword lists being traversed before rejection;
- duplicated option keys silently receiving last-write behavior;
- deep/cyclic-looking or very large acyclic terms consuming excessive caller
  work before a sandbox boundary;
- unrelated structs, functions, PIDs, ports, or references reaching code that
  assumes inert Lisp data;
- different public boundaries using slightly different recursive projectors;
- map/set collisions after key or leaf projection;
- eager `inspect/2` or string interpolation revealing a native payload before a
  later redaction step; and
- retained-size and encoded-size limits being applied in different orders.

These are broader than Java values and should be evaluated independently.

### Candidate direction: bounded option preflight

Consider a small `OptionPreflight` used by public execution/compiler entry
points before ordinary `Keyword` access.

Possible contract:

- bounded outer-list length;
- proper two-element keyword entries only;
- closed allowed atom keys;
- duplicate-key rejection;
- no traversal or inspection of option values during the outer pass; and
- stable invalid-options errors before telemetry or sandbox creation.

Do not apply this automatically to presentation APIs such as formatting. Their
option vocabularies and error contracts are different.

### Candidate direction: named validation episodes

If generic recursive validation is needed, avoid one deadline spanning unrelated
parsing, waiting, evaluation, and publication work.

Potential episode kinds:

- `:host_ingress` for caller-supplied nested host values;
- `:source_static` for RawAST analysis, CoreAST validation, and static walks;
- `:tool_result` for one newly returned callback value;
- `:continuation_candidate` before committing memory/history; and
- `:publication` for one public/event/inspection projection.

An episode could share depth, node, byte, and deadline counters among the
validators participating in that one contiguous operation. Nested validators
must not reset the counters. Parsing/evaluation/tool waiting should retain their
existing independent limits.

Before adopting this design, measure current worst-case behavior and prove that
the additional deadline does not reject valid bounded compilation on slower CI
hosts.

### Candidate direction: closed boundary policies

A shared traversal could apply named leaf/container policies without feeding the
lossy output of one policy into another. Candidate policies include:

- inert public Elixir values;
- strict canonical JSON;
- type-preserving private ledger encoding; and
- the current `json/generate-string` contract.

Any design must explicitly define:

- ordinary atoms and Lisp keywords;
- special numeric values;
- arbitrary binaries and UTF-8 requirements;
- tuple, set, and map-key behavior;
- Program/source opacity;
- callable values;
- host temporal structs;
- projection collision detection; and
- stable bounded errors.

This is substantially larger than adding Java leaf clauses to current
projection and should not be smuggled into an interop feature.

### Candidate direction: bounded inspection/redaction

Review structs that may retain source, closures, tool arguments/results,
continuations, or cache entries. Candidates for custom bounded `Inspect`
implementations include Result/Step, ToolCache, Program, callable wrappers, and
other authority-bearing values.

Potential rules:

- display counts and safe type labels, not payloads;
- never enumerate nested child results merely for `inspect/2`;
- forged/malformed structs remain safe to inspect;
- Logger and `format_status` never expose retained secrets; and
- user-visible formatting remains a deliberate API separate from debugging
  inspection.

Tests should use unique sentinel values across successful/failing results,
memory, closures, prompts/messages, child steps, tools, and cache entries.

## Area B: tool projection and cache identity

### Observed concerns

Direct-host tools and Kernel JSON tools have different callback contracts. Tool
arguments, private ledgers, encoded-size checks, result validation, and cache
keys can drift if each derives its own projection from the native value.

Potential generic issues:

- cache identity built from a value different from what the callback observes;
- atom/string or hyphen/underscore key normalization collisions;
- direct-host and Kernel JSON calls accidentally sharing a cache entry;
- callbacks returning unsupported BEAM authority-bearing values;
- cache hits bypassing validation applied to fresh results;
- forged cache entries or stale entries surviving a tool contract change;
- private/non-cacheable tools entering a cache; and
- cache/result inspection exposing arguments or results.

### Candidate direction: prepared tool views

Consider one preparation step that validates the native value against the
declared signature and produces explicitly owned views:

- callback arguments;
- JSON-safe size/ledger representation;
- cache identity; and
- redacted observability metadata.

Cache identity must be derived from the selected callback-visible value. A
direct Elixir callback and a Kernel JSON callback should not share an entry just
because their native inputs describe the same semantic object.

### Candidate direction: opaque cache records

If current evidence justifies a cache redesign, consider entries containing:

- normalized tool name;
- boundary mode;
- explicit tool generation/version;
- tool contract digest;
- collision-safe argument identity;
- validated native result for direct-host mode; and
- bounded ledger/size metadata.

Questions requiring an explicit decision:

- whether cache-enabled public tools must provide a generation and result
  contract;
- whether Kernel tools remain non-cacheable;
- whether cache hits rerun native result validation;
- how old plain-map cache state is rejected in this 0.x library; and
- whether cache contents remain in-process structs or move behind an owner.

This should be a standalone tool/cache change with representation-sensitive
callbacks and fresh-versus-hit parity tests.

## Area C: Kernel event publication and terminal finalization

### Observed concerns

Current event publication and terminal assembly use several read-then-act paths.
Potential races or drift include:

- reading dropped-event state and then emitting a summary separately;
- ordinary event capacity suppressing `run-stopped`;
- computing final usage before terminal event loss is known;
- owner death being mistaken for proof that all unlinked producers are quiet;
- persistence reading a mutable sink after execution;
- trace and inspection persistence receiving different event batches;
- failure telemetry recursively replacing the original failure with a sink
  error; and
- no-clobber retry behavior after publication succeeds but acknowledgement is
  lost.

These concerns affect every Kernel run, not Java interop.

### Candidate direction: split capabilities

Investigate replacing an all-purpose EventSink handle with distinct internal
capabilities:

- producer capability/lease for ordinary emission;
- lifecycle capability for exactly one terminal finalizer; and
- read capability for bounded observation and persistence.

Do not adopt this until all current consumers are inventoried, including:

- `Runner`;
- `RunBuilder`;
- `ReplSession`;
- `TraceLog` and `TraceCapability`;
- `InspectionArtifact`;
- Viewer/session trace code; and
- tests or embedding hosts that read an in-memory sink.

The design must state how a finalized immutable batch reaches every persistence
and query consumer. Removing a broad handle without a replacement read path
would break current trace behavior.

### Candidate direction: producer leases

If terminal ordering requires proving producer quiescence, track every process
that can emit:

- evaluation owner;
- sandbox worker;
- provider task; and
- spawned descendants that receive emission authority.

A spawn path would acquire or transfer a monitored lease before the child can
emit. Finalization closes new lease admission and waits for all accepted leases
and synchronous emission calls to drain. An evaluation-owner `:DOWN` initiates
cleanup but does not prove an unlinked provider/sandbox is finished.

This adds meaningful complexity and should be justified with concrete current
races and focused failure tests.

### Candidate direction: atomic terminal finalization

One owner operation could:

1. close producer admission;
2. wait for producer quiescence;
3. snapshot bounded drop accounting;
4. append `events-dropped` when required;
5. compute final event-aware usage;
6. append exactly one `run-stopped`; and
7. freeze/return the immutable terminal batch.

The sink would reserve count/byte capacity for its maximum code-owned terminal
records. Ordinary producer events could not consume that reserve.

Questions that must be answered before implementation:

- who owns finalization for ordinary Runner, standalone REPL, and Viewer
  sessions;
- how invalid or repeated finalization is rejected;
- whether private sinks emit a drop summary;
- how the public Result receives the identical final usage;
- how a finalized batch reaches RunBuilder and TraceLog;
- when sink/read owners terminate; and
- how construction failures before `run-started` are represented.

### Candidate direction: bounded drop accounting

Normal-policy loss state should have a fixed maximum number of event-type
buckets plus an overflow counter. Unique attacker-controlled event types must
not grow sink state without bound or collide with a real event name.

An atomic failure-event admission returning `:dropped` must also update normal
drop accounting in the same owner operation. Otherwise finalization can omit
`events-dropped` and `TraceLog.truncated` will be false despite known loss.

### Candidate direction: failure-envelope floors

If public projection failures are recorded through bounded Results, events, and
inspection records, each containing boundary needs a minimum capacity for its
complete envelope, not only for an inner payload.

A future plan should distinguish:

- direct public result limit;
- Kernel terminal result limit;
- ordinary event payload/record limit;
- inspection record limit;
- aggregate event/inspection storage limits; and
- TraceLog source/query-result limits.

Use generated maximum fixtures and production encoding rather than representative
examples. Do not repurpose TraceLog query limits as event-production limits.

### Candidate direction: no-clobber trace publication

For Viewer/session persistence, a complete batch could be:

1. encoded and validated before opening the destination;
2. written and synced to an exclusive same-directory temporary file;
3. published with an atomic no-replace operation;
4. considered successful on retry only when an existing destination is
   byte-identical; and
5. cleaned up without exposing a partial discoverable trace.

Fault injection should cover failure before write, during write, after sync,
after publication but before acknowledgement, and during cleanup.

## Area D: REPL and Viewer lifecycle ownership

### Standalone ReplSession

`ReplSession` is currently an immutable transferable value rather than a process
owner. If a future EventSink lifecycle capability is PID-bound, it must not be
bound casually to the process that called `ReplSession.new/1`; that process may
hand the session to another process and exit.

One possible design is a supervised run-scoped `ReplLifecycle` process:

- the session value stores an opaque handle;
- the process owns finalization and deadline cleanup;
- evaluation/sandbox/provider processes receive producer leases only;
- `ReplSession.close/1` and admitted abort operations delegate to it;
- creator death does not invalidate a transferred session; and
- repeated/stale close cannot finalize twice.

This is not required merely to retain Java wrappers in REPL memory. Adopt it
only as part of an approved lifecycle redesign.

### Viewer SessionTrace

The existing Viewer log-analysis plan already has its own session and persistence
ownership design. If the shared EventSink lifecycle changes later, reconcile
that plan then rather than editing it as part of Java interop.

Potential future properties:

- `SessionTrace`, not standalone `ReplLifecycle`, owns Viewer finalization;
- explicit abort reasons use a closed public enum;
- unexpected owner death derives an internal reason rather than trusting
  caller input;
- orderly close, recoverable owner death, and Viewer shutdown use one
  drain/finalize/persist path;
- persistence failure retains only the immutable batch/destination/retry state;
- successful persistence retains at most a lightweight bounded tombstone when
  `info/1` or idempotent `close` must survive a lost response; and
- Reset retires the prior handle only after persistence/start reconciliation.

These requirements belong in the Viewer plan when that work is implemented.

## Area E: reusable conformance process supervision

The Java plan needs a bounded pinned JVM/Babashka subprocess harness. A more
general long-lived oracle service may be useful later if subprocess cleanup,
parallel case throughput, or telemetry attestation becomes unreliable.

Possible components:

- bounded adapter-level concurrency;
- one case owner and one execution worker per case;
- a surviving reaper that owns OS ports and temporary directories;
- registration of compile/evaluation sandbox descendants before execution;
- callback barriers before detaching telemetry handlers;
- process-tree termination on timeout, cancellation, owner death, or adapter
  shutdown; and
- no case-slot release until handlers, BEAM children, OS children, ports, and
  temporary files are quiescent.

This design should be triggered by measured harness problems. The initial Java
conformance implementation should prefer a simple bounded subprocess per case
or batch.

## Suggested decomposition

Do not implement this file as one change. If evidence supports the work, split
it into independent plans:

1. **Host ingress and boundary algebra**
   - option preflight;
   - named validation episodes;
   - projection policies/collision handling; and
   - bounded inspection/redaction.

2. **Tool projection and cache identity**
   - prepared callback/ledger/cache views;
   - cache schema/versioning; and
   - fresh/hit parity.

3. **EventSink and terminal publication**
   - capability ownership;
   - producer leases;
   - terminal reserve/finalization;
   - frozen batch routing; and
   - drop/failure accounting.

4. **Trace/Viewer persistence lifecycle**
   - no-clobber publication;
   - retry/tombstone semantics;
   - owner-death cleanup; and
   - Reset reconciliation.

5. **Reusable conformance worker supervision**
   - only if the simple oracle harness proves insufficient.

Each plan must begin by reproducing a concrete defect or documenting a clear
contract gap in current code.

## Decision gates

Before promoting an area from future research to implementation:

- identify the current production path and consumers;
- demonstrate the bug, race, leak, drift, or unbounded behavior;
- state the smallest contract that fixes it;
- show why existing ownership/limits cannot be extended locally;
- keep Viewer, REPL, Runner, direct Lisp, and Kernel differences explicit;
- define migration and deletion of the replaced path;
- add focused success/failure/timeout/owner-death tests in proportion to risk;
- update durable module docs/guides rather than linking implemented code to this
  future plan; and
- pass `mix precommit` before committing and `mix prepush` before pushing.

## Relationship to bounded Java interop

The Java plan may proceed independently using these narrow rules:

- validate Java wrappers where they enter or are consumed;
- retain them only at native/continuation boundaries;
- add focused Java leaf handling to current public/tool/Kernel projection;
- reject or inertly render Java callables at non-native boundaries; and
- test nested values and projection collisions.

If that implementation exposes a concrete generic boundary defect, record it
here and propose the smallest separate fix. Do not make the entire future
hardening backlog a prerequisite for correcting Java semantics.
