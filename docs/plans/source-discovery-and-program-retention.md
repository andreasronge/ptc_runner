# Source discovery and generated-program retention

**Status:** implementation-ready design; proposed APIs are not implemented.
Current behavior and the feasibility decisions below were verified against
`origin/main` on 2026-08-31.

PtcRunner already preserves source in several places, but each surface answers a
different question. This note inventories those surfaces and proposes a smaller
active-session API for inspecting components, following their dependencies, and
optionally returning the programs produced by one nested agent loop.

The goal is not one universal source browser. The goal is a coherent answer for
each lifetime:

- shipped documentation before an application is loaded;
- exact code attached to the current workflow or mission;
- programs produced by a nested agent loop while its caller is still running;
- exact historical evidence from a completed recorded run; and
- candidate files prepared for a later override.

## Vocabulary

This note uses four different source terms deliberately:

- A **definition** is one `def`, `defn`, or reachable private helper addressed
  by a qualified ref such as `agent.prompt/render`.
- A **component** is one selected source unit addressed by component ID, such as
  `agent.prompt`. One component can contain several definitions and namespaces.
- A **generated program** is one model-authored PTC-Lisp source string admitted
  to a subordinate mission evaluation.
- A **recorded source** is an immutable component or generated-program source
  recovered from a completed run's private inspection artifact.

Component IDs and namespaces are not interchangeable. The compiler supports a
component ID that differs from the namespace declared by its source.

## What exists now

### Shipped documentation

The standalone executable carries its documentation:

```console
ptc docs
ptc docs agent-library
ptc docs preludes
ptc docs functions
```

This is the right surface for stable contracts. It does not load an application
and does not expose the exact effective source of a local component or override.

### Active PTC-Lisp introspection

Every evaluation has these discovery forms:

```clojure
(dir)                         ; attached namespaces
(dir "agent.core")            ; visible exports in one namespace
(apropos "prompt")            ; visible callable-name search
(doc "agent.core/run")        ; callable contract, printed
(export-meta "agent.core/run") ; callable contract as data
(source agent.core/run)       ; one defining form, printed
```

`doc` also covers fixed built-ins and installed capability contracts.
`export-meta` remains an attached-prelude view. `source` deliberately has no
registry or filesystem fallback and reveals implementation only for the current
attached environment.

There are two current gaps:

1. There is no component-level operation. The REPL cannot list component IDs,
   read a component's direct dependencies, or retrieve its complete source.
2. Definition source is broken for ordinary composed bundles. Each component
   compiler builds `Prelude.source_index`, but `Prelude.Compiler.compose/3`
   does not merge those indexes, so a manifest-backed REPL reports no source
   even for attached exports.

The second item is a bug, independent of the component API proposed below.

### Active component identity

The frozen bundle already knows the active component graph. Each frozen
component carries:

- component ID;
- direct dependency IDs;
- declared namespaces;
- effective source hash; and
- bounded provenance.

`FrozenBundle.trace_metadata/1` projects the same graph as ordered
`component_ids` plus aligned `dependency_indices`. The canonical `run-started`
event records that projection. The evaluator does not currently expose it as a
PTC-Lisp value.

The exact source bytes are available while the application package is built and
are emitted to private inspection, but `BundleCompiler` drops them from each
frozen component after compilation. A component-source API therefore needs an
explicit bounded source-bearing projection; it cannot reconstruct exact source
from definition forms. That projection must not be added to
`Prelude.metadata.components`: `Prelude.trace_summary/1` copies that metadata
into every Lisp result, which would disclose all attached source without an
explicit `component` call and enlarge every result and trace.

### Generated programs during the calling workflow

`agent.core/run-outcome` currently returns only the outcome:

```clojure
{:status :returned :value value}

{:status :subject-failure
 :kind kind
 :error error}

{:status :provider-failure
 :error error
 :model alias}
```

The agent loop retains its correlated conversation while it runs, but no public
option copies admitted generated programs into that returned outcome.
`run-value`, `run-result-value`, and `run-phased-result-value` return a successful
value directly. `agent.core/run` terminates the outer workflow.

### Generated programs and component source after a run

Private inspection already retains the exact evidence:

```clojure
(analysis/read run-id {"collection" "generated_sources"})
(analysis/read run-id {"collection" "prelude_sources"})
(analysis/read run-id {"collection" "turns"})
```

`generated_sources` contains exact admitted subordinate-evaluation source,
source identity, mission and evaluation identity, static prelude-call analysis,
and typed relationships. `prelude_sources` contains the exact effective source
of every frozen workflow and mission component. `turns` joins model turns to
matching generated programs when the evidence permits it.

The relationship surface can navigate:

```text
generated program
  -> referenced component source
  -> direct dependency component sources
```

The public canonical trace contains component IDs, hashes, dependency
projections, and evaluation facts, but not exact source. Host logs and telemetry
also exclude source. Exact source requires the private inspection artifact and
the `private-run-analysis-v2` profile. `ptc transcript` is a convenience for one
private conversation; it is not a general component-source export command.

### Candidate materialization

The standalone command can validate and run an existing component-override
descriptor. Creating one is still a source-checkout workflow:

```console
cp priv/preludes/kernel/agent.prompt.clj private/agent.prompt.clj
mix ptc.materialize ptc.json --workflow --component agent.prompt \
  --source private/agent.prompt.clj --out private/candidate
```

`mix ptc.materialize` already owns source hashing, owner-only no-clobber
publication, descriptor construction, re-acquisition, compilation, contract
checks, and effect-widening checks. REPL values are preview-bounded and a
manifest REPL has no exact raw-source file output, so the guide cannot safely
replace this `cp` with output scraping.

Add the current materializer to the standalone command and give it a distinct
source-export mode. Exporting and candidate publication must be two steps:
`descriptor.json` hashes the exact `candidate.clj` bytes, so publishing a
descriptor and then telling the operator to edit its candidate would make the
descriptor invalid.

First export the installed effective source from the same project or manifest
used by `run`, without provider acquisition:

```console
ptc materialize ptc-project.json --workflow \
  --component agent.prompt --source-out private/agent.prompt.clj
```

After editing that file, create and gate the immutable candidate artifact:

```console
ptc materialize ptc-project.json --workflow \
  --component agent.prompt --source private/agent.prompt.clj \
  --out private/agent-prompt-candidate
```

`--source-out` and `--source`/`--out` are mutually exclusive modes. Both accept
`--target-mission NAME` instead of `--workflow`. Source export writes one
owner-only file, refuses an existing destination, and never creates a partial
candidate descriptor. Candidate mode retains the current Mix task's hashing,
compilation, contract, effect-widening, confinement, cleanup, and owner-only
publication rules. The standalone resolver accepts a project or manifest; the
source-checkout Mix spelling remains a thin entry to the same implementation.

The installed bundle accepts up to 2,000,000 aggregate source bytes, while the
existing override and candidate contract accepts at most 1,048,576 bytes for
one replacement. Keep those independent limits: inspection/export must work
for every accepted component, while candidate mode continues to reject a
replacement over its existing 1 MiB trust boundary. Document that diagnostic
instead of silently raising an unrelated limit as part of this feature.

This remains separate from in-language self-inspection: `component` returns
data so an agent can understand itself, while `ptc materialize` intentionally
creates files for a later edit and run.

## Proposed active component API

### Use data, not the print channel

The earlier minimal proposal overloaded `source`:

```clojure
(source "agent.prompt")
```

That spelling is brief, but the existing `source` contract prints text and
returns `nil`, following `clojure.repl/source`. Printed text is truncated by the
evaluation print budget, whose default is 2,000 characters. `agent.prompt` is
already much larger than that, so this would appear simple while failing the
self-inspection use case.

Keep `source` as definition-oriented printed introspection and add one
source-bearing component value instead:

```clojure
(components)
;; => ["agent.failure" "agent.feedback" ... "agent.core" ...]

(component "agent.core")
;; => {:id "agent.core"
;;     :dependencies ["agent.machine" "agent.native" "agent.prompt"
;;                    "kernel" "llm" "result" "workflow.event"]
;;     :namespaces ["agent.core"]
;;     :source-hash "sha256:..."
;;     :source "(ns agent.core ...)"}
```

This adds two names but only one data shape. An agent can bind the value and
inspect a large source in bounded slices without asking the host to print the
whole string:

```clojure
(def prompt-component (component "agent.prompt"))
(subs (get prompt-component :source) 0 2000)
```

The short guide example becomes:

```console
ptc> (component "agent.core")
ptc> (component "agent.prompt")
```

No separate `component-meta`, `component-source`, `component-tree`, or
`dependencies` function is needed.

### Component semantics

The proposed forms have these rules:

- `(components)` returns component IDs from the current workflow or selected
  mission environment in frozen dependency order.
- `(component id)` resolves one exact attached component ID and returns `nil`
  when it is absent.
- `:dependencies` contains direct edges only. A caller recursively resolves
  them; the API does not render a nested tree that duplicates shared nodes.
- `:source` is the complete exact effective component source, including private
  helpers and an active component override.
- `:source-hash` is computed from those exact source bytes.
- `:origin` is omitted. A local origin may disclose a host path and is not
  needed to understand or replace the component.
- There is no shipped-library catalog or filesystem fallback. An unattached
  component remains unavailable.
- Existing environment visibility still applies. A workflow REPL describes its
  workflow bundle; `--mission NAME` describes that mission bundle.
- A direct `PtcRunner.Lisp.run/2` evaluation has no Kernel component graph,
  even when it receives a source prelude or selection list. In that environment
  `(components)` returns `[]` and `(component id)` returns `nil`. The same
  answers apply through higher-order invocation. Direct prelude composition is
  not silently promoted into the stricter Kernel component model.

The same boundary applies when these forms run outside an interactive REPL. A
model-authored mission program could inspect components attached to that
mission, but it could not inspect the workflow's `agent.core` component. A
coding agent driving a workflow REPL could inspect `agent.core`. Making the
workflow loop source visible inside its generated-program mission would be a
new cross-environment disclosure channel and is outside this proposal.

Returning complete source broadens implementation disclosure beyond the current
reachable-private-helper rule. That is intentional only for an attached
component and must be documented as such. Component source must never contain
credentials; the same warning already applies to source-bearing preludes and
private inspection.

### Make source inspection independent of provider credentials

An ordinary project or manifest REPL assembles the live environment, so it
correctly requires the selected providers, credentials, and capabilities even
when the first expression is only `(component ...)`. That behavior should not
be weakened: a live REPL must retain the same authority and call surface as the
application it represents.

Add an explicit offline inspection mode instead:

```console
ptc repl --project ptc-project.json --inspect-only
ptc repl --project ptc-project.json --mission analysis --inspect-only
```

`--inspect-only` resolves the project or manifest, selects and compiles the
workflow or named mission, and attaches its component catalog without loading
a host document, environment file, input, provider session, or capability.
It attaches the real compiled prelude so discovery visibility still equals the
callable PTC-Lisp surface: pure attached functions may be evaluated, while an
operation that crosses into an unavailable Kernel, provider, or capability
route fails with one closed `inspect_only_unavailable` diagnostic. It does not
install fake providers or capability stubs. A startup notice says that this is
a compile-and-inspect environment, not a runnable application environment.

The option requires `--project` or `--manifest`; it may be combined with
`--mission`, scripts, stdin, or `-e`, but conflicts with `--host-config`,
`--env-file`, runtime input, trace/inspection output, private-session switches,
and analysis profiles. Its preparation path must use package acquisition and
bundle compilation directly rather than `RunCoordinator.prepare/2`, so a
missing DeepSeek or other provider credential cannot fail source inspection.
Normal REPL behavior and diagnostics remain unchanged when the flag is absent.

### Source storage, projection, and limits

Introduce an immutable attested component catalog for each selected
environment. In frozen dependency order it binds each component ID to its
direct dependencies, declared namespaces, qualified
`sha256:<64-lowercase-hex>` source hash, and exact source bytes. Build it from
the same `%Component{}` values passed to `BundleCompiler`; validate its order,
graph, namespaces, and hashes against the resulting `%FrozenBundle{}` before
attestation. Add that binding to both workflow and mission environment
attestation so source cannot be paired with a different compiled bundle.

The catalog is separate from `%Prelude{}` metadata. The evaluation context
receives only the selected environment's catalog; direct `PtcRunner.Lisp.run/2`
receives none. Neither normal result stamping, `Prelude.trace_summary/1`,
canonical traces, telemetry, nor host logs may traverse or project it. Source
enters ordinary workflow data only when evaluated code explicitly returns a
value obtained from `component`.

Preserve the existing 2,000,000-byte aggregate source-input ceiling per bundle
instead of introducing a second caller-configurable limit. During package
preparation, intern identical exact source binaries by qualified SHA-256 and
reuse them across workflow and mission catalogs; guard a hash collision by
comparing bytes and fail closed if they differ. This permits the already valid
worst case of one workflow plus sixteen distinct 2 MB mission source sets
without copying a 34 MB aggregate catalog into every sandbox. Each evaluation
sees at most its own already-admitted 2 MB catalog, and shared large binaries
remain shared BEAM binaries.

The catalog is setup memory, not compiled-artifact output, but that does not
make it free: sandbox setup still has its own heap/binary-sharing behavior.
Acceptance therefore includes heap measurements at the per-environment and
maximum-mission boundaries. If those measurements show copying rather than
binary sharing, change the transport before shipping; do not add a lower
source-inspection limit that makes a previously valid bundle fail only because
inspection exists.

Tests must also cover repeated components shared by several missions, hash
collision defense, and a file mutation after package acquisition to prove the
reported bytes are the bytes compiled. Ordinary public Lisp results and
canonical traces must contain no source unless code explicitly returns
`component`; that explicit result remains subject to ordinary evaluation and
terminal-result limits.

### Keep definition source

The existing form remains useful and should be repaired rather than replaced:

```clojure
(source agent.prompt/render)
```

It answers “where is this callable defined?” while `component` answers “what
code unit is attached, and what does it depend on?” Fix composition by merging
the per-component `source_index` and keep its current visibility checks.

## Proposed in-run generated-program retention

The proposed opt-in follows the explicit configuration precedent used by
standalone named return contracts:

```clojure
(agent.core/run-outcome
  task
  {"mission" "analysis"
   "retain_programs" 32})

;; => {:status :returned
;;     :value value
;;     :programs [{:turn 1
;;                 :mission "analysis"
;;                 :source "..."}
;;                ...]
;;     :programs-omitted 0}
```

Rules proposed here:

- Omitted or `nil` means no retention and preserves the current outcome shape.
- A present value is an integer from 1 through 128 and is validated before the
  first provider or mission activity.
- Retention includes only source admitted to a subordinate mission evaluation,
  matching the core meaning of the historical `generated_sources` collection.
  Protocol errors and source rejected before evaluation are not fabricated as
  evaluated programs.
- Entries are ordered by one-based loop turn and contain only `:turn`,
  `:mission`, and exact `:source`. They do not copy evaluation IDs, hashes,
  static call analysis, model messages, observations, or evidence
  relationships from private inspection.
- When more than the requested count is admitted, retain the most recent
  entries so the terminal attempt remains reviewable and report the exact
  `:programs-omitted` count.
- Independently cap retained source at 2,000,000 UTF-8 bytes. Keep the newest
  complete entries that satisfy both limits; never truncate a source string.
  An individual admitted program larger than that retention cap is omitted in
  full and counted. The cap is code-owned and not a second configuration knob.
- If the loop returns a subject or provider failure after earlier evaluations,
  attach the same retained list to that outcome. Host and infrastructure
  failures that abort the outer evaluation still have no returned outcome.
- When retention is enabled, every returned outcome contains `:programs` and
  `:programs-omitted`, including `[]` and `0` when no source was admitted.
- Retention is workflow data, not inspection evidence. If the caller returns
  it from the application, ordinary result classification and publication
  rules apply.

### Admission boundary

“Admitted” means that `kernel-eval` has passed the subordinate source-byte and
evaluation-lease checks, emitted `evaluation-started`, and accepted the source
for execution. Creating an evaluation ID or reaching `agent.core`'s
`:evaluate` command is not admission. Consequently:

- terminal-source rejection, protocol rejection, source-byte rejection, and a
  busy or evaluation-budget refusal are not retained;
- compile failures, runtime failures, explicit mission failures, and successful
  evaluations after that boundary are retained; and
- an inspection- or event-sink failure still aborts the outer run and has no
  outcome to annotate.

The trusted `kernel-eval` response must carry `:admitted? true` on every
returned post-admission outcome and omit it before that boundary. Add the fact
only after source and lease admission, `evaluation-started`, and private source
capture have succeeded, but before compile/execute. `agent.core` appends the
action's exact program only after authenticating that exact boolean on the
reserved trusted response; it must not infer admission from an evaluation ID,
an `:evaluate` command, or a generic response status. Strip the marker before
observation rendering and before any value reaches the model.

`:turn` is the one-based global agent turn, including across phased-loop
transitions; it is not the phase-local turn. `:mission` is the exact selected
mission name for that evaluation.

### Restrict the option to `run-outcome`

The initial proposal named both `run-outcome` and `run-value`. Only
`run-outcome` has a stable envelope that can gain a sibling `:programs` field.
`run-value` returns the model-authored value directly; making an option change
that success into `{:value value :programs [...]}` would make its return type
configuration-dependent and break composition.

Keep `retain_programs` on `run-outcome` only. A workflow that needs both
fail-fast behavior and programs can inspect the outcome and choose its own
propagation policy. Do not add `run-with-programs`, `run-record`, or parallel
variants until a concrete caller proves that the outcome form is insufficient.

`run-result-value` and `run-phased-result-value` also have callers, despite
being described informally as result-oriented entries. Their direct-value
return shape creates the same problem as `run-value`; “terminating entries have
no caller” is not a sufficient selection rule.

### Count is not a complete byte bound

The count makes retention finite, but it does not make the returned value
predictably publishable:

- `max_program_chars` defaults to 64,000 but accepts up to 1,000,000;
- `max_transcript_chars` defaults to 262,144 and accepts up to 1,000,000; and
- `terminal_result_bytes` defaults to 1,000,000, with a larger installed
  ceiling available.

For example, 128 programs at the default per-program ceiling are about 8 MB,
while 32 programs at the accepted 1,000,000-character maximum are much larger.
The evaluator heap and terminal-result ceilings still fail closed, but a
count-only option can make an otherwise successful loop fail when its outcome
is encoded.

Use a 2,000,000-byte aggregate retained-source ceiling. It matches the standard
installed subordinate-source ceiling, permits several programs at the default
131,072-byte runtime limit, and bounds the ring independently of a host that
raises its runtime source ceiling. A valid admitted program can therefore be
too large to retain; omission is explicit rather than turning this review
feature into a new run-admission rule. Count UTF-8 bytes with `byte_size`, evict
oldest whole entries until both count and bytes fit, and increment
`:programs-omitted` once per discarded entry.

The terminal result contains the returned value as well as retained programs,
so it can still exceed `terminal_result_bytes`; existing encoding and
publication checks fail closed. The retained-source cap must be included in the
generated agent reference and tested independently of that terminal-result
limit.

Do not add both `retain_programs` and a caller-selected byte option unless a
real application needs independent count and byte control. Two knobs would be
more precise but would work against the goal of a small review API.

## Consistency analysis

The resulting surface separates contracts, active implementation, nested-loop
data, and historical evidence:

| Question | Current or proposed surface | Lifetime | Result channel |
| --- | --- | --- | --- |
| What does shipped PTC support? | `ptc docs PAGE` | installed executable | terminal documentation |
| What can I call here? | `dir`, `apropos`, `doc`, `export-meta` | active environment | printed contract or bounded data |
| How is one callable defined? | repaired `source ref` | active environment | bounded print channel |
| What components are attached? | proposed `components` | active environment | data |
| What is this component's graph and exact code? | proposed `component id` | active environment | data |
| What programs did this nested loop admit? | proposed `run-outcome` `:programs` | current workflow | explicitly retained workflow data |
| What exactly happened in a completed run? | `analysis/read` private collections | recorded run | private paged evidence |
| How do I prepare an override artifact? | current `mix ptc.materialize`; proposed `ptc materialize` | later invocation | owner-only files |

This is consistent in five ways:

1. **Current and historical state stay separate.** Active introspection never
   opens trace artifacts; private analysis never pretends to describe the
   currently loaded bundle.
2. **Contracts and implementation stay separate.** `doc` and `export-meta`
   describe how to call something; `source` and `component` disclose code.
3. **Structured navigation returns data.** Component graphs and complete
   component source do not depend on a print channel intended for human-sized
   output.
4. **Rich evidence stays in inspection.** The in-run program list is a small
   opt-in projection, not a second copy of model exchanges, evaluation joins,
   static call analysis, or relationship semantics.
5. **Source disclosure is explicit.** The active source catalog is not trace
   metadata and is never projected automatically. Only `component` can move an
   attached source string into ordinary workflow data.

The data classification is equally explicit. Attached component source is
application implementation data, consistent with the existing `source` form
and the rule that component files must not contain credentials. Generated
programs returned by `run-outcome` inherit the run's effective normal or
private flow; existing destination authorization therefore requires a private
destination when private inputs or inspection made the flow private. Neither
API is a declassification mechanism. Historical exact source remains private
inspection data, and `materialize --source-out` writes owner-only output
unconditionally because its next use may be a private candidate workflow.

## Documentation restructure

The documentation should lead with a short choice, not make a reader assemble
the lifecycle from the REPL, component, and debugging references. Add one brief
guide and one cross-surface reference, then keep the subsystem references as the
owners of their detailed contracts.

### Add one brief inspection guide

Add `docs/guides/inspecting-source-and-programs.md`, titled **Inspect source and
generated programs**. Keep it below 350 words, with one small routing table and
no exhaustive option, field, limit, or failure lists. It should explain why the
executable program matters: the model's narration states intent, while the
admitted PTC-Lisp program is the executable decision that shows the functions,
tools, data, and return or failure path actually chosen. Reviewing it supports:

- debugging a failed or surprising result;
- verifying correctness and authority use;
- human or automated review before accepting a result or candidate; and
- improving a prompt or component through an explicit inspect, edit, replay,
  and compare cycle. Inspection does not mutate the active bundle or
  automatically promote a self-authored replacement.

The guide should route four common tasks with only minimal examples:

| Need | Brief guide example | Detailed owner |
| --- | --- | --- |
| inspect one definition in the active environment | `(source agent.prompt/render)` | REPL and function references |
| inspect an attached shipped or local component and its direct dependencies | `(component "agent.prompt")` | source-inspection and component references |
| review programs admitted by a nested loop before the workflow ends | `run-outcome` with `"retain_programs"` | agent-library and source-inspection references |
| recover exact programs and component source from a completed run | `analysis/read` on private inspection | debug-navigation reference |

The guide should state the essential authority distinction in one paragraph:
public traces carry identities, hashes, dependency projections, and outcomes,
but not source; host logs and telemetry are not source-export surfaces; exact
historical source requires explicitly enabled private inspection. It should
link to the new source-inspection reference for the full selection matrix,
limits, return shapes, and privacy rules.

### Add one cross-surface reference

Add `docs/reference/source-inspection.md`, titled **Source-inspection
reference**. This page owns the exhaustive answer to “where can this source be
retrieved?” across these lifetimes:

1. installed documentation and callable contracts through `ptc docs`, `doc`,
   and `export-meta`;
2. one active defining form through `source`;
3. the active workflow or mission component graph and exact effective source
   through `components` and `component`, for shipped libraries, local
   components, and active overrides alike, including credential-free
   `repl --inspect-only` preparation;
4. admitted programs returned to a live caller through `retain_programs`; and
5. exact generated programs, component sources, turns, and typed relationships
   from completed runs through private inspection.

An application's own attached prelude is not a separate retrieval mechanism:
local and shipped components use the same active `component` shape. The
reference should distinguish that Kernel component graph from a direct
`PtcRunner.Lisp.run/2` source prelude, which deliberately returns `[]`/`nil`.
For dependency navigation, active inspection exposes direct component IDs for
recursive lookup, while completed-run inspection follows the recorded typed
relationships. Neither path reconstructs dependencies from host log text.

The reference owns the comparison table for availability, authority, exactness,
return channel, lifetime, and limits. It also owns the active component return
shape, direct-Lisp `[]`/`nil` behavior, workflow-versus-mission isolation,
post-admission definition, omission semantics, automatic-projection
prohibition, and the distinction between public trace facts and private source.
It links rather than repeats:

- REPL selectors, output previews, profiles, and private-session rules from
  `docs/reference/repl.md`;
- component compilation, dependencies, overrides, and candidate descriptors
  from `docs/reference/component-contracts.md`;
- analysis collections, filters, pagination, evidence completeness, and typed
  relationships from `docs/reference/debug-navigation.md`; and
- the generated function, prelude, agent-library, and limits references for
  exact callable signatures and ceilings.

### Update the customization guide

Keep `docs/guides/components-and-preludes.md` as the short “try and keep a
component change” workflow; do not turn it into the source reference. Rename
its title to **Inspect and customize components**, inspect the installed prompt
briefly in an inspect-only project REPL, and replace the repository copy step
with the two honest lifecycle steps:

```console
ptc materialize ptc-project.json --workflow \
  --component agent.prompt --source-out private/agent.prompt.clj
# edit private/agent.prompt.clj
ptc materialize ptc-project.json --workflow \
  --component agent.prompt --source private/agent.prompt.clj \
  --out private/agent-prompt-candidate
```

The next sentences say to validate the resulting descriptor and compare it with
replay. The guide must not mention `priv/preludes`, require a Git checkout,
scrape REPL previews, or duplicate descriptor fields and hash rules. It links
to the source-inspection reference for retrieval choices and to the component
reference for replacement rules. Keep the permanent-new-ID rule and the
warning that an override applies only to a later invocation.

### Align existing references without duplicating them

Update these existing owners when the APIs land:

- `docs/reference/repl.md` lists `components` and `component` beside the other
  discovery functions, defines which selected environment they inspect,
  specifies `--inspect-only` and its conflicts, and links to the
  source-inspection reference.
- `docs/reference/component-contracts.md` documents both `ptc materialize`
  modes, including project/manifest resolution, workflow and mission
  selection, exact effective `--source-out`, owner-only no-clobber publication,
  and authored `--source` candidate gating. It keeps ownership of descriptor,
  size, and replacement validation.
- `docs/reference/debug-navigation.md` keeps ownership of completed-run
  collection and relationship navigation. Add only a short contrast with
  active `component` inspection and in-run `retain_programs`, then link to the
  source-inspection reference.
- `docs/reference/cli.md` and the command declarations document the standalone
  materializer's grammar and diagnostics.
- `priv/functions.exs` owns generated `components` and `component` entries;
  the shipped `agent.core` docstrings and generator own `retain_programs` in
  `docs/agent-library-reference.md` and `docs/prelude-reference.md`. Do not edit
  generated references directly.
- `docs/guides/kernel-repl.md`, `docs/guides/debugging-a-failed-run.md`, and
  `docs/guides/agent-cli-usage.md` get at most one routing sentence or link each;
  they do not repeat the new guide.

Register the new guide and reference in `mix.exs`, put the guide under **Run and
debug**, expose both through the shipped `ptc docs` catalog with short stable
page names, and let `mix ptc.gen_docs` regenerate the site guide and sidebar.
Update link/catalog tests and command fixtures through their owning generators.

### Documentation acceptance

- Planned APIs remain labelled as planned until their implementation lands;
  public guides describe only the released behavior.
- The new guide stays below the repository's new-guide caps and the existing
  customization guide does not grow. Run `scripts/guide_budget.sh report` while
  editing and `scripts/guide_budget.sh check` before submission.
- One canonical reference owns every exhaustive rule; guides contain no copied
  field tables, limit tables, schemas, or failure algebra.
- Tests cover every visible command example that can be deterministic, all
  internal documentation links, the shipped `ptc docs` catalog, generated
  artifact freshness, and absence of the old checkout-only `cp` example.
- Run `mix ptc.gen_docs`, `MIX_ENV=dev mix docs --warnings-as-errors`, and the
  relevant documentation and command tests before the repository gates.

## Implementation readiness

The design decisions are closed enough to implement without another public API
round:

- active navigation is exactly `components` plus `component`;
- definition-level `source` keeps its current printed contract and is repaired;
- credential-free preparation is the explicit `repl --inspect-only` mode, not
  weakened live-REPL acquisition;
- installed-source export and candidate publication are two modes of
  `ptc materialize`, not one editable hashed artifact;
- program retention exists only on `agent.core/run-outcome`, with count range
  1..128 and a fixed 2,000,000-byte newest-whole-entry ring; and
- exact historical evidence remains in private inspection rather than being
  duplicated into traces or logs.

Implementation should begin with the catalog and admission-boundary types,
because those are the trust anchors. CLI and Lisp functions should project
those types instead of independently rebuilding graphs, hashes, or admission
logic.

### Acceptance matrix

| Area | Required acceptance evidence |
| --- | --- |
| Definition source | A composed workflow and mission REPL return the correct reachable defining form; private and unattached definitions remain unavailable. |
| Active catalog | Shipped, local, and active-override components return exact compiled bytes, qualified hashes, deterministic dependency order, direct edges, and declared namespaces; absent IDs return `nil`. |
| Environment boundary | Workflow and mission catalogs remain isolated; direct and higher-order `PtcRunner.Lisp.run/2` calls return `[]`/`nil`. |
| Inspect-only REPL | Project and manifest workflow/mission forms work with deliberately missing provider credentials and start no provider/MCP process; live REPL behavior without the flag is unchanged; every conflicting option is rejected before activity. |
| Catalog integrity | Attestation rejects graph/hash/source mismatch, a guarded collision, and catalog/bundle substitution; a source-file mutation after acquisition cannot alter returned bytes. |
| Disclosure and limits | No ordinary trace, telemetry, host log, result stamp, or prelude summary contains catalog source. Explicit component return obeys heap, print-preview, and terminal-result limits. Per-bundle 2 MB and sixteen-mission memory boundaries are measured. |
| Program admission | Success, compile failure, runtime failure, and explicit mission failure after admission are retained. Protocol, terminal-source, oversize-source, busy, and budget refusal before admission are excluded. The marker never appears in model-visible observations. |
| Program ring | Opt-out is byte-for-byte shape compatible. Opt-in validates before activity, returns empty fields when appropriate, uses global phased turns, retains newest whole entries under both limits, counts every omission, and handles one admitted source larger than 2 MB. |
| Failure and privacy | Subject/provider outcomes include prior retained programs; infrastructure aborts return no invented outcome. Normal/private destination authorization is unchanged, and source never appears automatically in inspection-disabled runs. |
| Materialization | `--source-out` resolves project or manifest, workflow or mission, shipped/local/override bytes without providers; it is 0600, no-clobber, symlink-safe, and cleans partial writes. Editing then running candidate mode produces a descriptor whose hashes match the edited bytes; stale-base and over-1-MiB candidates fail with their existing diagnostics. |
| Packaged UX | The standalone executable, source-checkout Mix task, `ptc help`, and `ptc docs` expose the same contract. Deterministic guide commands run without a repository checkout. |

Use focused unit and integration tests while implementing, then run the
repository gates appropriate to the changed surfaces:

```console
scripts/guide_budget.sh check
mix ptc.gen_docs
MIX_ENV=dev mix docs --warnings-as-errors
scripts/ci/core-tests.sh
mix precommit
mix nightly
```

`mix nightly` is required because this changes standalone/Mix CLI and
interactive REPL paths. Add a packaged-release smoke test for inspect-only and
both materialize modes. Run the heap benchmark and `mix soak` for the catalog
transport before merging; they are acceptance evidence for retained large
binaries, not routine documentation gates. Live-provider E2E is unnecessary
for inspect-only correctness, but one existing provider-backed REPL E2E must
remain green to prove the normal path was not weakened.

### Risks and mitigations

- **Memory amplification.** Exact sources can total 34 MB across the maximum
  application. Per-environment catalogs, interning, large-binary reuse, heap
  measurements, and soak coverage prevent that aggregate from being copied
  into each evaluator. Treat unexpected copying as a release blocker.
- **Implementation disclosure.** `component` exposes private helpers for an
  attached component. Keep access environment-local and explicit, prohibit
  automatic projection, retain the no-credentials-in-components rule, and
  test all public recording surfaces for absence.
- **Catalog/source mismatch.** A separately carried source map could lie about
  the compiled bundle. Construct both from one acquired component set, compare
  against the frozen graph and hashes, attest the pair, and test TOCTOU and
  substitution failures.
- **Misleading offline authority.** A provider-free REPL could appear fully
  runnable. It attaches the compiled PTC-Lisp prelude so discovery and
  callability stay consistent, but installs no provider or capability; external
  routes fail with a closed diagnostic, and a startup notice states the
  boundary.
- **Invalid edited descriptors.** Editing a published candidate changes its
  hash. The two-step export/edit/materialize flow makes the hash only after the
  edit and keeps each mode no-clobber.
- **Returned-value amplification.** Count alone is not a byte bound. The fixed
  2 MB ring, whole-entry omission, exact omission count, and existing terminal
  result limit keep behavior bounded and visible.
- **Admission drift.** Retaining attempted rather than admitted programs would
  disagree with historical `generated_sources`. One trusted post-admission
  boolean, stripped before observations, and boundary tests make the two
  meanings coincide.
- **Limit inconsistency.** Inspection accepts a 2 MB aggregate bundle while a
  replacement remains limited to 1 MiB. Keep the existing candidate trust
  boundary and document the precise error; changing it later requires its own
  memory and security review.

## Implementation slices

Keep the work separable, but land the trust-boundary changes before their user
surfaces:

1. Repair composed definition source by merging `source_index`, with
   manifest-backed workflow and mission REPL tests.
2. Introduce and attest per-environment component catalogs, intern exact source
   binaries during package preparation, and add integrity, TOCTOU, disclosure,
   heap, and maximum-mission tests.
3. Implement `components` and `component` over that catalog, including
   direct-Lisp/higher-order empty behavior, environment isolation, override
   bytes, and result-limit tests.
4. Add `repl --inspect-only` through package acquisition and bundle compilation
   without `RunCoordinator`, providers, inputs, capabilities, traces, or
   private-session authority. Cover project/manifest and workflow/mission CLI
   paths plus the startup notice and conflicts.
5. Add the trusted post-admission fact to `kernel-eval`; authenticate and strip
   it in the agent loop before implementing `retain_programs` only on
   `run-outcome`, with the fixed byte ring and complete acceptance cases above.
6. Promote the existing Mix materializer implementation into the standalone
   command, add private no-clobber `--source-out`, and keep candidate mode as
   the post-edit hashing/gating step. Cover the packaged executable and the
   unchanged 1 MiB candidate boundary.
7. Update owning module docs, command declarations, `priv/functions.exs`, and
   shipped prelude docstrings; regenerate all derived references and fixtures.
8. Add the source-inspection reference, rewrite the customization guide, add
   the brief inspection guide, and update only the routing links and catalogs
   listed above.
9. Run the full acceptance matrix and gates, record the catalog heap/soak
   evidence in the PR, and fix every failure before merge.

When a slice lands, move its exact contract into the owning module docs,
`priv/functions.exs` or shipped prelude docstrings, and the relevant guide.
Remove this plan when no proposed work remains.
