# Minimal Programmable Kernel — V1 Contract

**Status:** proposed normative contract for the implementation spike. Core
runtime decisions are specified for approval; manifest/frontend schemas are
gated at Slice 8.

**Implementation branch:** `exp/minimal-kernel`, created from
`exp/lisp-kernel` only when implementation begins.

## Purpose

The Kernel runs a bounded PTC-Lisp workflow with two explicitly constructed
capability environments and provides safe subordinate Lisp evaluation.

It does not define an LLM protocol, agent turn, prompt policy, retry policy,
conversation format, planning system, or completion contract. Those are shipped
PTC-Lisp libraries.

The public V1 interface is:

```elixir
PtcRunner.Kernel.compile_bundle([PtcRunner.Kernel.Component.t()])

PtcRunner.Kernel.run(
  entry_source,
  %PtcRunner.Kernel.RunConfig{}
)
```

`entry_source` is bounded UTF-8 source text. `%RunConfig{}` has exactly these
fields:

- `workflow_environment` — a frozen `%WorkflowEnvironment{}`;
- `mission_environment` — a frozen `%MissionEnvironment{}`;
- `input` — one bounded JSON-like map with binary keys;
- `limits` — one normalized `%Limits{}` with no disabled hard limits;
- `event_sink` — one bounded sink descriptor, never an arbitrary callback;
- `labels` — optional bounded, sanitized run labels.

The two environment structs and `%RunState{}` are the final V1 module names.
Environment constructors are the only public way to assemble them. They reject
unknown fields, duplicate capabilities, reserved-name conflicts, invalid data,
and unsatisfied prelude requirements before `run/2` begins.

Conceptually this remains:

```text
run(entry_expression,
    workflow_environment,
    mission_environment,
    input,
    hard_limits,
    event_sink)
```

BEAM code owns authority, containment, resource enforcement, provider
boundaries, state ownership, and unavoidable runtime facts. PTC-Lisp owns
workflow behavior.

### Construction phases

Construction is deliberately split into two phases:

```text
compile_bundle(components) -> frozen_bundle
assemble_environment(frozen_bundle, capabilities, data) -> environment
```

Bundle compilation validates source, component identity, dependency structure,
namespaces, exports, provenance, and recorded `requires`. Environment assembly
validates those recorded requirements against the capabilities actually granted
to that environment. Compilation never grants authority and does not need an
environment.

## Inputs

### Entry expression and bundles

`Kernel.run/2` executes one bounded entry expression. Namespace-bearing
workflow files are compiled before the run as components of a frozen workflow
bundle. Mission preludes are compiled as a separate frozen mission bundle.

A manifest selects one qualified entry function. The run builder constructs an
entry expression such as:

```clojure
(workflows.research-report/run data/input)
```

The manifest does not contain an arbitrary executable entry expression. Direct
embedding and tests may pass a literal entry expression such as:

```clojure
(return (+ 40 2))
```

V1 accepts source text for the entry expression. Compiled entry programs are
deferred until a measured caching need exists.

### Input

The Kernel receives one input map. Agent workflows conventionally use:

```elixir
%{"task" => "Research the subject",
  "context" => %{}}
```

The workflow receives it as explicit data, not through an ambient configuration
namespace. Binary keys remain Lisp strings; Kernel does not implicitly
keywordize host input.

### Frozen bundles

`compile_bundle/1` accepts an explicit closed set of source or already compiled
components and returns one immutable bundle. V1 uses fixed conservative bundle
limits rather than adding a second configuration surface during the spike.

A component contains:

- an ID matching `[a-z][a-z0-9._-]{0,127}`;
- exactly one of bounded UTF-8 `source` or a compatible compiled artifact;
- a sorted, duplicate-free list of component-ID dependencies;
- a bounded sanitized origin;
- recorded namespace, export, and `requires` metadata.

Compiled artifacts are accepted only when their compiler-format version is
supported and their encoded artifact checksum verifies. V1 source components
hash raw UTF-8 bytes with SHA-256. A frozen bundle records compiler-format
version, source hash/provenance when present, and ordered component hashes.

It:

- uses component ID as the sole dependency-graph identity;
- resolves the local component DAG deterministically;
- rejects missing dependencies and cycles;
- rejects duplicate component IDs, namespace conflicts, and incompatible
  exports;
- records component IDs, dependency edges, source origins, and hashes;
- validates protected namespaces and export metadata.

When several graph nodes are ready, lexicographic component ID is the
topological tie-breaker. "Incompatible exports" means duplicate qualified
public refs, a public/private collision at the same qualified ref, or conflicting
signature/effect metadata for a qualified ref.

Compilation is independently bounded by component count, dependency-edge
count, aggregate source bytes, compile time, compile heap, frozen-artifact bytes,
and diagnostic bytes. It is not covered by the later run deadline.

Namespaces identify Lisp code and exports; they are not a second dependency
graph. Selection, fetching, version choice, roles, and stores happen outside
`compile_bundle/1` and `run/2`.

`run/2` accepts only environments containing frozen workflow and mission
bundles. Active bundles cannot
be mutated during a run.

## Two environment confinement

Every run has two structurally distinct environments.

### Workflow environment

Contains:

- the host-selected entry workflow;
- workflow and agent-loop preludes;
- the reserved `kernel-eval` capability;
- read-only changing runtime usage;
- bounded workflow annotation;
- configured workflow capabilities such as `llm/request`.

The workflow is sandboxed but authority-bearing.

### Mission environment

Contains only:

- subordinate PTC-Lisp programs, commonly model-generated;
- the frozen mission prelude bundle;
- explicit mission capabilities such as files, HTTP, logs, and databases;
- mission input/context exposed through `data/*`;
- transactional evaluation memory.

### Enforcement invariant

> `kernel-eval` constructs the subordinate evaluator exclusively from a
> `%MissionEnvironment{}`. It never accepts, inherits, merges, or falls back to
> a workflow environment.

Consequently subordinate code cannot reach `llm/request`, recursively invoke
`kernel-eval`, emit privileged events, inspect workflow capabilities, or acquire
authority merely because the outer workflow has it.

Environment membership authorizes execution. Presentation metadata does not.
A capability absent from an environment cannot be invoked by guessing its
name.

Capability objects are reusable and environment-neutral. They do not carry a
`scope: :workflow | :mission` flag. Scope arises only during environment
assembly.

Prelude `requires` metadata validates availability but never grants authority.
Workflow-prelude requirements are validated against the workflow environment;
mission-prelude requirements are validated against the mission environment.

The model-visible symbol and data inventory is derived exclusively from the
mission environment.

## Capabilities

### Representation

A capability has:

- a stable name;
- bounded documentation;
- a strict host-constructed argument schema;
- presentation metadata such as `model_visible: false`;
- a host callback or borrowed provider handle.

Capability values and provider handles remain exclusively in host-owned
environment maps. Lisp receives only sanitized metadata and an unforgeable
dispatcher route; no callback, closure environment, provider handle, grant, or
environment struct is representable as a Lisp value.

Presentation controls inventory rendering only. Avoid `private` terminology as
an authorization concept.

For V1, manifests select providers from a host registry. They cannot name
arbitrary Elixir modules, functions, or callback terms.

Providers return only `{:ok, json_value}` or
`{:error, %PtcRunner.Kernel.ProviderError{}}`. `json_value` is recursively
limited to nil, booleans, finite numbers, UTF-8 binaries, lists, and maps with
unique binary keys. Provider errors use a closed host atom vocabulary and
bounded binary details. Bare values, exceptions, PIDs, ports, references,
functions, structs, and arbitrary atoms are invalid provider returns.
The reserved host-internal `kernel-eval` capability is not a manifest-selectable
provider and is the only V1 dispatch route allowed to receive an opaque Program
value. Its discriminated schema rejects Program values on the source path and
strings on the embedded path.

### Elixir/Lisp value boundary

PTC-Lisp keeps its existing atom-safe keyword representation: keywords from the
bounded runtime vocabulary may be atoms and novel source keywords are
`%PtcRunner.Lisp.Keyword{name: binary}`. Arbitrary source text is never converted
to a BEAM atom.

At capability dispatch:

- Lisp keyword map keys become binary provider keys using the keyword name;
- Lisp string keys remain binary provider keys;
- a map containing both a keyword and string key that normalize to the same
  binary is rejected as an ambiguous argument;
- provider binary map keys remain Lisp strings in domain values;
- the dispatcher alone constructs keyword-keyed dispatch envelopes and the
  closed keyword vocabulary used by their `:status`, `:kind`, `:reason`, and
  `:outcome` fields.

Run input and manifest/provider domain data are JSON-like binary-keyed values.
They are not implicitly keywordized.

### Dispatch semantics

The host dispatcher:

- validates and bounds arguments before provider invocation;
- atomically reserves the applicable environment and per-capability budget;
- applies a per-call timeout within the remaining run deadline;
- contains callback raises, exits, hangs, invalid returns, and oversized
  results;
- records effect attempts before dispatch where auditability requires it;
- bounds and normalizes values before they re-enter Lisp;
- invalidates borrowed results when the run closes;
- prevents late callback results from re-entering Lisp or mutating run state.

Each callback runs in its own monitored process with an explicit provider heap
ceiling; BEAM process limits are not inherited. The dispatcher also bounds the
number of live provider tasks. A callback may be killed after timeout, but
already-issued external effects and descendants owned by trusted provider code
cannot be rolled back by Kernel.

A validated dispatch attempt consumes capability budget even if the provider
fails. Argument-validation failures do not invoke the provider and are counted
as protocol errors.

External cancellation is best effort. The hard guarantee is that a timed-out or
closed result cannot resume the workflow or commit state.

Host-selected providers are trusted extension code. Kernel contains their
ordinary raises, exits, hangs, invalid returns, and result sizes, but it is not a
security boundary against a provider that deliberately creates ETS tables,
ports, unlinked descendants, or VM-global state. Adversarial providers or
tenants require a separate node or OS/container boundary.

### Uniform result envelope

Every host capability returns a keyword-keyed Lisp dispatch envelope:

```clojure
{:status :ok
 :value value}
```

or:

```clojure
{:status :error
 :kind :timeout
 :reason :provider-timeout
 :retryable? true
 :details {...}}
```

The host dispatcher constructs the envelope; providers do not invent their own
success/error conventions. Arbitrary model-authored keyword names are not
converted to BEAM atoms.

Dispatch status and domain outcome remain distinct. Successful subordinate
dispatch may return:

```clojure
{:status :ok
 :value {:outcome :returned
         :value 42}}
```

or:

```clojure
{:status :ok
 :value {:outcome :evaluation-error
         :kind :unknown-symbol
         :details {...}}}
```

Lisp programming errors outside capability dispatch abort that evaluation; they
are not capability errors.

### Dispatch failure matrix

| Condition | Capability budget | Lisp result | Outer Kernel result |
| --- | --- | --- | --- |
| Argument/schema failure | Not consumed; protocol-error counter increments | `{:status :error :kind :protocol-error ...}` | None unless workflow chooses to fail |
| Capability absent from active environment | Not consumed | Evaluation fails with environment-local `capability-denied` | Outer workflow aborts; subordinate evaluation returns `:capability-denied` |
| Total/per-name quota exhausted | Not consumed beyond the exhausted count | `{:status :error :kind :limit-exceeded ...}` | None unless workflow chooses to fail |
| Provider error or raise/exit | Consumed | `{:status :error :kind :provider-error ...}` | None unless workflow chooses to fail |
| Provider timeout | Consumed | `{:status :error :kind :timeout ...}` | None unless the run deadline is also exhausted |
| Invalid provider result | Consumed | `{:status :error :kind :invalid-result ...}` | None unless workflow chooses to fail |
| Oversized provider result | Consumed | `{:status :error :kind :result-exceeded ...}` | None unless workflow chooses to fail |
| Run closed/deadline exhausted | Not dispatched | No late value re-enters Lisp | `:limit-exceeded` |
| Dispatcher/owner invariant failure | As atomically recorded before failure | No recoverable envelope is fabricated | `:internal-error` |

All rows emit bounded canonical attempt/stop facts when the event policy permits.
Provider failures never become an outer Kernel error merely because the
provider failed; workflow policy decides whether a recoverable envelope is
terminal.

## Safe subordinate evaluation

`kernel-eval` is the essential authority-crossing workflow capability:

```clojure
(tool/kernel-eval {:kind :source :source source})
```

It always:

- accepts only a mission environment;
- validates source size before parsing;
- reserves a subordinate-evaluation budget atomically;
- evaluates sequentially under evaluation timeout and heap limits;
- exposes only mission data, mission capabilities, and the mission bundle;
- starts from the current evaluation memory;
- measures candidate memory before commit;
- commits acceptable memory transactionally;
- preserves prior memory on failure or oversize;
- returns a bounded domain outcome in the uniform dispatch envelope.

Only a successfully completed evaluation may commit candidate memory. This
includes a definition-only program that reaches normal end-of-input and a
program that executes `return`. `fail`, parse/analyze/runtime errors, capability
denial, timeout, heap kill, result oversize, retained-memory oversize, or run
closure always release the lease and preserve the prior memory exactly.

It has no agent turn number, pending LLM action, or native-tool handshake.
Correlation policy belongs to the outer workflow; the host may assign immutable
evaluation IDs for tracing.

### Static embedded subordinate programs

V1 adds one narrow special form for statically authored subordinate code:

```clojure
(program
  (def x 40)
  (return (+ x 2)))
```

`program` captures its body without evaluating it in the workflow environment
and produces one opaque bounded Program value. This is the only macro-like
evaluation behavior introduced for this use case. It does not add general
collection quoting, quasiquote/unquote, macros, AST manipulation, or general
`eval`.

An opaque Program contains only bounded code identity and diagnostic data, such
as canonical source or parsed forms, origin/span when known, byte size, and
digest. It never captures:

- workflow lexical values or resolved workflow symbols;
- closures or runtime callables;
- capability/provider handles;
- workflow or mission environment references;
- interpolated runtime data.

The workflow parser parses captured forms and reports malformed syntax. The
workflow analyzer validates the `program` form's shape and bounds, then treats
its body as an environment boundary:

- it does not resolve captured symbols against the workflow environment;
- it does not infer workflow-prelude `requires` from captured mission calls;
- it does not evaluate captured expressions;
- it emits one opaque Program value.

Full analysis occurs when the Program is evaluated against the mission
environment and current evaluation memory. This permits a static Program to
reference definitions created by an earlier subordinate evaluation without
being incorrectly rejected during workflow compilation.

### Static and dynamic evaluation APIs

Shipped Lisp helpers expose two explicit operations:

```clojure
(kernel/eval
  (program
    (return (+ data/x data/y))))
```

and:

```clojure
(kernel/eval-source source)
```

`kernel/eval` accepts only an opaque Program. `kernel/eval-source` accepts only
bounded source text, including model-generated code. Do not overload one
function based on whether an argument happens to be a string.

Both remain ordinary Lisp functions over the one reserved host capability:

```clojure
(tool/kernel-eval {:kind :embedded :program program-value})
(tool/kernel-eval {:kind :source :source source})
```

The dispatcher validates the discriminated request and exactly one
representation. Both paths use the same mission environment, evaluation
memory, hard limits, transactional commit, result envelope, and tracing.
The raw `tool/kernel-eval` route is reserved but callable by workflow Lisp so
the helpers remain ordinary library code. It is absent from the mission
environment and mission inventory.

No interpolation is supported in V1. Changing values cross the boundary only
through explicit mission input/context:

```clojure
(kernel/eval
  (program
    (return data/value)))
```

Program bodies cannot capture workflow locals through unquote or any equivalent
mechanism.

### Program opacity and resource rules

V1 does not support converting Programs to lists, walking/rewriting their AST,
concatenating forms, unquoting, using them as macro bodies, or general dynamic
namespace loading. Optional inspection is limited to bounded metadata such as
`program?`, byte size, and digest. Source rendering for diagnostics/traces is
bounded by the selected projection policy.

Embedded programs remain subject to all relevant limits:

- captured bytes count against workflow compilation/source limits;
- evaluated bytes count against subordinate source limits;
- each invocation reserves a subordinate evaluation;
- analysis/evaluation remains within the run deadline and heap limits;
- Program values count toward workflow heap/retained-size enforcement;
- Program values cannot escape as arbitrary public results and are projected
  only as bounded opaque metadata when needed.

The implementation may pre-parse or cache a Program, but this optimization must
not bypass mission-environment analysis, current evaluation memory, or any
limit enforced for dynamic source.

Program diagnostics should map to the original workflow origin and inner spans
when end-to-end span preservation exists. Until then, diagnostics may refer to
canonical rendered subordinate source and must state that limitation.

Program identity is the SHA-256 digest of canonical UTF-8 source rendered from
the captured forms. Its `byte_size` is the canonical-source byte size. The
entire containing workflow source is still charged to workflow source limits;
the canonical Program bytes are charged again on each subordinate evaluation.
When parser spans exist, origin metadata may additionally identify the exact
original source slice without changing Program identity.

## State

Two Lisp state domains exist:

- **workflow state** — ephemeral outer-evaluation locals and control state;
- **evaluation memory** — definitions and bounded values persisted across
  successive `kernel-eval` calls.

The public result may expose only a bounded evaluation-memory summary. Workflow
locals are never public state and do not survive the run.

One run-owned process atomically owns:

- deadline and closed status;
- workflow capability counters;
- mission capability counters;
- subordinate-evaluation counters;
- evaluation memory;
- dropped-event accounting.

State mutations use single owner-process operations. A separate read followed
by update is forbidden.

V1 allows ordinary workflow capability calls to run concurrently where existing
PTC-Lisp constructs permit it, subject to task and capability limits.
Subordinate evaluation itself is serialized: at most one `kernel-eval` may hold
the evaluation-memory lease. A concurrent request is not queued; it consumes no
subordinate-evaluation budget and returns a recoverable
`{:status :error :kind :busy :reason :evaluation-in-progress ...}` envelope.
Mission programs may use bounded parallel data operations, but a mission
environment cannot invoke `kernel-eval` recursively.

## Hard limits

Kernel limits are measurable host resources, not agent concepts:

- wall-clock run duration;
- total and per-name workflow capability calls;
- total and per-name mission capability calls;
- subordinate evaluations;
- protocol errors;
- entry and subordinate source bytes;
- per-evaluation timeout and heap;
- retained evaluation-memory bytes;
- capability argument/result bytes;
- annotation, event, and terminal-result bytes.

The normalized V1 defaults are application-independent and conservative:

| Limit | Default |
| --- | ---: |
| Run duration | 30,000 ms |
| Workflow/subordinate evaluation timeout | 30,000 / 1,000 ms |
| Workflow/subordinate heap | 8,000,000 / 1,250,000 words |
| Provider task heap | 5,000,000 words |
| Live provider tasks | 8 |
| Workflow capability calls, total/per name | 64 / 16 |
| Mission capability calls, total/per name | 128 / 32 |
| Subordinate evaluations | 16 |
| Protocol errors | 32 |
| Entry/subordinate source | 262,144 / 131,072 bytes |
| Retained evaluation memory | 2,000,000 bytes |
| Capability argument/result | 262,144 / 1,000,000 bytes |
| Event payload/terminal result | 262,144 / 1,000,000 bytes |
| Normal event queue | 256 events and 4,000,000 aggregate bytes |

Bundle defaults are 128 components, 512 dependency edges, 2,000,000 aggregate
source bytes, 5,000 ms compile time, 8,000,000 compile-heap words, 4,000,000
frozen-artifact bytes, and 65,536 diagnostic bytes. Numeric limits are positive
integers; V1 has no `nil`, zero, or infinity escape hatch. Embedders may lower or
raise normalized limits before construction, but frontends apply their own
administrator ceilings and untrusted manifests cannot exceed them.

Retained-size accounting is the conservative `PtcRunner.Lisp.RetainedSize`
measure, not exact physical memory. Shared referenced binaries may be counted
more than once. Heap limits are per BEAM process, not whole-node limits.

`max_turns`, retries, planning steps, and other workflow policy are Lisp
configuration below these ceilings.

The wall deadline begins after configuration, paths, providers, environments,
and frozen bundles have been validated and constructed. It covers workflow
evaluation, subordinate evaluation, providers, required event delivery, final
projection, and run closure.

Bundle compilation occurs before the run deadline under the independent bundle
limits above.

## Runtime facts and discovery

Changing usage is read-only host state:

```clojure
(runtime/usage)
(runtime/remaining)
```

Snapshots include elapsed/remaining time, subordinate evaluations,
evaluation-memory bytes, and workflow/mission capability calls by name. Lisp
may use them for soft policy but cannot mutate counters or increase ceilings.

Immutable run ID, deadline, and environment-local capability metadata should be
explicit input data where possible.

Capability discovery is environment-local:

```clojure
(cap/list)
(cap/describe "search")
```

or an equivalent immutable input projection. Each environment can discover
only its own capabilities. Metadata is bounded, deterministic, and sanitized.

## Events

The Kernel emits canonical unavoidable runtime facts to a bounded run-owned
sink. It does not invoke arbitrary callbacks directly in the execution path.

The minimum normal event vocabulary is:

- `run-started` and exactly one attempted `run-stopped`;
- `evaluation-started` / `evaluation-stopped` for workflow and subordinate
  evaluations;
- `capability-started` / `capability-stopped` for validated dispatch attempts;
- `limit-exceeded`;
- `workflow-annotation`;
- `events-dropped`.

Every event has schema version, run ID, trace ID, monotonic sequence, UTC
timestamp, type, and bounded data. Applicable events add evaluation ID,
capability ID, environment (`workflow` or `mission`), capability name, status,
and duration in integer milliseconds. The run-owned event process assigns
sequence and bounds payloads before enqueueing; producers cannot provide those
fields.

Normal tracing:

- preserves event order;
- bounds payloads before dispatch;
- uses bounded delivery;
- reports dropped-event counts;
- prevents sink failures from escaping as unrelated Kernel failures.

The normal sink uses the event-count and aggregate-byte queue limits in
`Limits`. Enqueue never blocks workflow execution. Once full, it drops later
normal events and atomically increments counts by event type. Before
`run-stopped`, Kernel attempts one bounded `events-dropped` summary; the same
counts are also present in terminal usage and `run-stopped` data so a full sink
cannot hide loss. Sink-worker failure closes normal delivery and is reported
through those counts rather than changing the workflow outcome.

Exact private transcript capture uses an explicit fail-closed sink policy where
loss is not permitted. Its delivery remains within the run deadline.
Its queue is still bounded, but enqueue applies backpressure within the remaining
deadline. Queue exhaustion, sink failure, or failure to flush before the
deadline closes the run with outer kind `:event_sink_error`; it never silently
falls back to normal lossy tracing.

Workflow code may emit a bounded annotation. The host stamps its type, run ID,
sequence, timestamp, and workflow-authored provenance. Workflow code cannot
forge lifecycle, capability, evaluation, limit, or terminal events.

The generic Kernel emits capability start/stop facts. Provider adapters may add
safe typed metadata—for example, an LLM adapter can support exact model request
transcripts without making Kernel understand LLMs.

Storage, run discovery, metadata, filtering, pagination, source grants, and the
model-facing `log/` prelude are specified in
[`tracelog-contract.md`](tracelog-contract.md).

## Public outcomes

The outer public algebra is:

```elixir
{:ok,
 %PtcRunner.Kernel.Result{
   value: value,
   usage: usage,
   evaluation_memory: bounded_summary
 }}
```

or:

```elixir
{:error,
 %PtcRunner.Kernel.Error{
   kind: kind,
   reason: reason,
   details: bounded_details,
   usage: usage
 }}
```

Stable V1 `kind` categories are small:

- `:workflow_failed`;
- `:limit_exceeded`;
- `:protocol_error`;
- `:event_sink_error`;
- `:configuration_error`;
- `:internal_error`.

Detailed `reason` values may evolve.

Subordinate outcomes are separate and recoverable: `:returned`, `:failed`,
`:evaluation_error`, `:capability_denied`, `:timeout`, `:memory_exceeded`, and
`:result_exceeded`. The workflow decides whether to retry, provide feedback,
fail, or return.

V1 does not impose a universal return contract.

## LLM and agent libraries

LLM access is an ordinary configured workflow capability:

```clojure
(llm/request request)
```

The host adapter owns credentials, provider transport normalization, request
and response ceilings, timeout/cancellation, accounting, and fault containment.

Shipped Lisp libraries own agent policy:

- `agent.native` — strict `run_ptc_lisp` schema and action parsing;
- `agent.core` — loop and message history;
- `agent.feedback` — correction rendering;
- `agent.retry` — retry/backoff decisions;
- `workflow.event` — semantic annotations;
- `result` — uniform result helpers.

Kernel does not construct forced model tools, match LLM and evaluation turns,
or decide completion. Alternative workflows may expose different model tools or
no model tools.

## PTC-Lisp API design rule

Prefer, in order:

1. Existing Clojure functions with Clojure semantics.
2. Composition in a prelude.
3. Namespaced Clojure-conventional library functions.
4. Standard host capabilities.
5. Special forms/primitives only when evaluation semantics require them.

Conventions:

- kebab-case names;
- `?` only for predicates;
- `!` only for externally visible mutation;
- essential positional arguments plus one final options map;
- qualified cross-library calls;
- keyword-keyed internal maps and string keys only at JSON/provider boundaries;
- deterministic observable ordering;
- bounded results with truncation metadata;
- one capability failure vocabulary.

Avoid macros, general `eval`, try/catch, mutable refs/atoms, dynamic namespace
loading, implicit imports, overloaded configuration DSLs, and agent-specific
special forms.

Retain terminal `return` and `fail` and transactional definition semantics.
Move `step-done`, journaling, SubAgent budgets, upstream catalogs, and agent
history out of the language core. `*1`, `*2`, and `*3` remain REPL conveniences.

## Diagnostics

Compilation and attachment are atomic. V1 diagnostics guarantee:

- one primary bounded error plus a small bounded set of related notes;
- stable phase and kind;
- symbol and namespace/function context when known;
- suggestions derived only from the active environment;
- no BEAM exception, stack, credential, filesystem, or other-environment
  details;
- failed compilation leaves the active bundle unchanged.

Accurate line/column spans are an explicit early language workstream. Until
span preservation exists end-to-end, location fields are present when known.
Complete source locations are required before model-editable preludes are
advertised as supported behavior.

Model-editable does not mean live self-modifying execution. Models may author
candidate source only through explicit grants. Compilation and promotion create
a new frozen bundle through a separate host-gated operation or later run.

## Manifest and frontend boundary

V1 uses one strict versioned JSON manifest with top-level `"version": 1`.
Unknown keys, duplicate JSON object keys, unsupported versions, non-UTF-8 input,
and values outside documented bounds are rejected. There is no YAML, TOML, or
implicit environment-variable substitution.

Source and input paths are relative to the canonical manifest directory. They
must resolve, after symlink resolution, to regular files beneath that directory;
absolute paths, traversal, devices, FIFOs, sockets, and symlink escape are
rejected. A host embedding API may construct environments from other paths
directly because it is already the authority boundary.

Trace destinations are relative to a separately configured administrator-owned
output root, not the manifest source root. Normal trace files are created without
following a final symlink. Private transcript directories/files use permissions
`0700`/`0600`, reject pre-existing unsafe ownership or permissions, and fail
closed on validation or write failure.

The manifest selects:

- workflow components and qualified entry;
- mission components;
- input/mission data;
- registered workflow providers such as an LLM adapter;
- mission capability providers and grants;
- hard limits;
- event/trace policy.

It cannot name arbitrary Elixir code.

The provider registry is a host-owned map from bounded provider name to a
trusted builder implementing the Kernel provider contract. PtcRunner ships a
small built-in registry; embedders may supply additional builders directly to
the run builder. Manifests contain only provider names and bounded provider
configuration accepted by the selected builder. A manifest cannot register,
replace, or point at a module, function, file, serialized callback, or code URL.

One loader/run builder serves `mix ptc.run` and future Docker, HTTP, Viewer Lab,
or optional MCP frontends. Server frontends should normally select
administrator-installed named manifests rather than accept arbitrary authority
grants.

## V1 non-goals

- roles and mutable prelude stores;
- MCP or a generic upstream subsystem;
- compiled entry programs;
- general collection quoting, quasiquote/unquote, macros, AST manipulation, and
  general `eval` beyond the opaque `program` form;
- return-contract enforcement;
- concurrent subordinate evaluation;
- live active-bundle mutation;
- general workflow capability injection from untrusted manifests;
- multiple manifest formats;
- streaming LLM workflows;
- chat lifecycle semantics.

## Slice gates still requiring concrete schemas

The architectural decisions formerly listed as open have proposed resolutions
above. Approve them in Slice 0. Before
Slice 1, the implementation commit must add exact struct types and validation
tests for `Component`, `Capability`, both environments, `Limits`, `RunConfig`,
`RunState`, provider errors, and event sinks. Before Slice 8, the manifest work
must add the complete JSON field schema, built-in provider-name list, per-field
bounds, and path test matrix. These are schema-definition tasks within the
approved boundaries above, not invitations to silently change authority or
execution semantics during implementation.
