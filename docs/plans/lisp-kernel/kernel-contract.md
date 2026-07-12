# Minimal Programmable Kernel — V1 Contract

**Status:** proposed normative contract. Resolve open decisions in this file
before runtime implementation begins.

**Implementation branch:** `exp/minimal-kernel`, created from
`exp/lisp-kernel` only when implementation begins.

## Purpose

The Kernel runs a bounded PTC-Lisp workflow with two explicitly constructed
capability environments and provides safe subordinate Lisp evaluation.

It does not define an LLM protocol, agent turn, prompt policy, retry policy,
conversation format, planning system, or completion contract. Those are shipped
PTC-Lisp libraries.

The irreducible interface is conceptually:

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

```clojure
{:task "Research the subject"
 :context {...}}
```

The workflow receives it as explicit data, not through an ambient configuration
namespace.

### Frozen bundles

`compile_bundle/1` accepts an explicit closed set of source or already compiled
components and returns one immutable bundle.

It:

- uses component ID as the sole dependency-graph identity;
- resolves the local component DAG deterministically;
- rejects missing dependencies and cycles;
- rejects duplicate component IDs, namespace conflicts, and incompatible
  exports;
- records component IDs, dependency edges, source origins, and hashes;
- validates protected namespaces and export metadata.

Namespaces identify Lisp code and exports; they are not a second dependency
graph. Selection, fetching, version choice, roles, and stores happen outside
`compile_bundle/1` and `run/2`.

`run/2` accepts only frozen workflow and mission bundles. Active bundles cannot
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
- an argument signature/schema;
- presentation metadata such as `model_visible: false`;
- a host callback or borrowed provider handle.

Presentation controls inventory rendering only. Avoid `private` terminology as
an authorization concept.

For V1, manifests select providers from a host registry. They cannot name
arbitrary Elixir modules, functions, or callback terms.

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

A validated dispatch attempt consumes capability budget even if the provider
fails. Argument-validation failures do not invoke the provider and are counted
as protocol errors.

External cancellation is best effort. The hard guarantee is that a timed-out or
closed result cannot resume the workflow or commit state.

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

## Safe subordinate evaluation

`kernel-eval` is the essential authority-crossing workflow capability:

```clojure
(tool/kernel-eval {:program source})
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

V1 subordinate evaluation is sequential.

## Hard limits

Kernel limits are measurable host resources, not agent concepts:

- wall-clock run duration;
- total and per-name workflow capability calls;
- total and per-name mission capability calls;
- subordinate evaluations;
- entry and subordinate source bytes;
- per-evaluation timeout and heap;
- retained evaluation-memory bytes;
- capability argument/result bytes;
- feedback, event, and terminal-result bytes.

`max_turns`, retries, planning steps, and other workflow policy are Lisp
configuration below these ceilings.

The wall deadline begins after configuration, paths, providers, environments,
and frozen bundles have been validated and constructed. It covers workflow
evaluation, subordinate evaluation, providers, required event delivery, final
projection, and run closure.

Bundle compilation normally occurs before the run deadline.

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

Normal tracing:

- preserves event order;
- bounds payloads before dispatch;
- uses bounded delivery;
- reports dropped-event counts;
- prevents sink failures from escaping as unrelated Kernel failures.

Exact private transcript capture uses an explicit fail-closed sink policy where
loss is not permitted. Its delivery remains within the run deadline.

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
- `:capability_error`;
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

V1 uses one strict versioned manifest format; JSON is the proposed choice.
Unknown keys are rejected. Paths resolve according to documented rules relative
to the manifest directory. Destinations such as private traces receive
additional safety validation.

The manifest selects:

- workflow components and qualified entry;
- mission components;
- input/mission data;
- registered workflow providers such as an LLM adapter;
- mission capability providers and grants;
- hard limits;
- event/trace policy.

It cannot name arbitrary Elixir code.

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

## Open decisions to close before implementation

- Confirm JSON as the V1 manifest format and freeze unknown-key/version rules.
- Freeze path-resolution and destination-safety rules.
- Freeze the built-in provider registry and its extension mechanism.
- Choose final module names for the two environment structs and run state.
- Freeze exact Elixir-to-Lisp keyword/string boundary encoding.
- Decide the minimum normal event vocabulary and dropped-event reporting shape.
