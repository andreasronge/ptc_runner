# Lisp Kernel product readiness

Status: active roadmap, reviewed 2026-07-13.

This document records the current limitations of the implemented minimal
Kernel and the work that would make it usable as a developer-facing product.
The [Kernel maintainer guide](../../guides/kernel-maintainer.md) maps the
implemented runtime and the `PtcRunner.Kernel.*` module documentation defines
its exact API. This document is a product assessment and may change as the
product surface develops.

## Assessment

The Kernel is implementable and its bounded-runtime foundation is working. It
is already useful for deterministic manifest workflows and focused LLM or
read-only file experiments from a repository checkout. The separation of
workflow and mission authority, immutable bundles, owner-process accounting,
hard limits, confined file access, and canonical events form a credible base.

It is not yet a general agent framework that a developer with basic Clojure or
agent-framework knowledge can adopt without Elixir expertise. The largest gap
is not evaluator safety. It is the product boundary around the evaluator:
discovering trusted libraries, adding useful capabilities, diagnosing invalid
manifests, configuring realistic model runs, packaging the runtime, and
operating it outside a Mix project.

The recommended next milestone is therefore **manifest-first
productization**, not a broader evaluator rewrite or a return to the deleted
SubAgent architecture.

## What works today

- Strict versioned JSON manifests can assemble local PTC-Lisp components,
  separate workflow and mission environments, input data, providers, limits,
  labels, and event policy.
- Component bundles are compiled before execution and include dependency,
  namespace, export, and tool-requirement validation.
- Run ownership and accounting are atomic, including late provider-result
  rejection after run closure.
- Run, workflow, mission-evaluation, heap, source, result, call, evaluation,
  and event limits are enforced.
- The built-in `llm` and mission-only `file-read` providers are confined by
  explicit environment authority.
- Manifest and file paths reject traversal and symlink escapes. JSON inputs are
  checked for duplicate keys and non-JSON host values are rejected.
- Canonical traces are bounded and sanitized, with normal and private source
  policies and a browser viewer for completed traces.
- Default run identifiers now use cryptographic entropy. This closes the
  cross-OS-process collision discovered while repeatedly running the CLI.
- Deterministic examples and focused Kernel contracts are covered by normal
  tests. Small live DeepSeek checks exercise the real provider boundary when
  E2E credentials are available.

See the [Kernel tutorial](../../guides/kernel-tutorial.md) for runnable examples
and the [Kernel maintainer guide](../../guides/kernel-maintainer.md) for the
implemented code map and invariants. Git history contains the completed
migration record.

## Current limitations

The priorities below describe product readiness, not defects in the current
Kernel execution boundary.

| Priority | Area | Current limitation | Consequence |
| --- | --- | --- | --- |
| P0 | CLI diagnostics | `mix ptc.run` reports many failures through `Mix.raise/1` and inspected Elixir terms; manifest failures often collapse to broad atoms such as `invalid_manifest`, `invalid_component`, or `invalid_limits`. | Scripts and non-Elixir users cannot reliably identify the failing file, field, phase, or repair. |
| P0 | Library access | Trusted shipped components such as `agent.core`, `agent.feedback`, `agent.retry`, `llm`, `fs`, and `result` are host-accessible, but a manifest can reference only local component files. | The main tutorial must carry a large local agent loop instead of selecting the runtime's tested library. |
| P0 | Limits | Manifest values are compared directly with `Limits.defaults/0`, so the defaults also act as hard ceilings. The default one-second evaluation and thirty-second run are too restrictive for many real model workflows. | Operators cannot set a higher safe ceiling while allowing a manifest to request a practical bounded model budget. |
| P0 | REPL parity | The REPL does not assemble the same reserved runtime tools as a normal workflow and uses the evaluation timeout for both the whole form and provider dispatch. | A manifest may work through `ptc.run` but fail or expose a different tool surface in `ptc.repl`; remote LLM calls are especially fragile. |
| P1 | Capability ecosystem | Manifests can select only built-in providers. Registering a normal application tool requires an Elixir callback; there is no constrained MCP, HTTP, or OpenAPI bridge. | Non-Elixir users cannot connect the Kernel to their existing tools without writing a host application. |
| P1 | Model protocol | The Kernel LLM adapter exposes a narrow request shape and does not carry structured-output schema, token limits, temperature/reasoning choices, or explicit provider timeout through the public manifest surface. | Model behavior is harder to constrain and operational budgets are incomplete. |
| P1 | Agent feedback | The shipped loop does not automatically receive a frozen inventory of mission exports and capability schemas. Evaluation corrections provide limited diagnostics, message history is not a full assistant/tool exchange, and the available retry helper is not integrated into the loop. | Models spend turns discovering authority, repeat protocol mistakes, and recover inconsistently. |
| P1 | Output contracts | A manifest cannot declare and enforce an input or terminal-result JSON Schema. Direct LLM calls return untrusted model text. | Hosts must add validation outside the manifest and successful runs may still return unusable data. |
| P1 | Trace operation | A malformed, duplicate, or oversized trace can make a directory source fail as a whole. Trace persistence is post-run, and the canonical sanitized vocabulary intentionally omits prompts, responses, arguments, results, and generated source. | One damaged file can hide healthy runs; crashes can lose buffered events; model debugging lacks a separate privacy-controlled transcript. |
| P1 | Host resources and prelude authoring | Trace access, private source inspection, and future prelude edits do not yet share an authenticated principal/grant contract. The Viewer is local and read-only; models and humans cannot create, validate, review, or promote versioned prelude candidates. | Generated programs and source preludes cannot be inspected through one safe product surface, and improving a prelude requires an out-of-band code change. |
| P1 | Distribution | The user workflow currently assumes a source checkout, Erlang/Elixir, and Mix. The viewer is a development/test path dependency rather than a production artifact. | Installation and deployment are too heavy for the intended non-Elixir audience. |
| P1 | End-to-end evidence | Normal tests cover the deterministic tutorial, while model examples mainly prove compilation/assembly and the live E2E check is intentionally small. There is no packaged-install or full CLI file-agent smoke test. | The most important user journey can regress across CLI, manifest, agent loop, provider, trace, and viewer boundaries without one test failing. |
| P2 | Language expectations | PTC-Lisp is Clojure-oriented, not a full Clojure implementation. The conformance report currently records 300 of 382 audited functions as supported, with notable gaps in `clojure.set` and `clojure.walk`. | Familiar-looking programs can encounter missing functions or semantic differences unless the supported profile is made explicit. |
| P2 | Viewer pagination evidence | The viewer's cursor API and event-accumulation code are tested and reviewed, but `Load more events` has not been exercised end to end in a browser with one valid run containing more than 100 events. | A pagination-only rendering, ordering, or interaction defect could remain despite the API checks. |
| P2 | Diagnostics | Parser/compiler/runtime failures do not consistently carry precise source spans through every boundary. | Larger component bundles are slower to repair than they need to be. |
| P2 | Reference quality | Some generated function-reference entries have minimal descriptions, and closed migration language remains in a few normative planning sections. | The documentation is accurate enough to implement against but not uniformly polished for first-time users. |

## Improvement details

### 1. Make the manifest the complete product boundary

The manifest is already the safest and simplest boundary for a non-Elixir
user. It should be able to express a useful workflow without copying runtime
library source into the project.

Add trusted, versioned library references alongside local components. A
reference should resolve only from an administrator-installed catalog and
should freeze:

- exact component source or content hash;
- transitive dependency closure;
- exported namespaces and functions;
- required capability names and schemas;
- runtime/library compatibility version.

A manifest must not load arbitrary executable code from the network or
register callbacks. The resolved components should enter the same immutable
bundle compiler as local components. With that surface, the tutorial agent can
select `agent.core` instead of maintaining a parallel agent implementation.

Add optional JSON Schema declarations for input and terminal output. Validate
input before a run acquires expensive authority and validate output before it
is reported as success. Schema errors should be bounded, structured, and safe
to show to a model when the workflow explicitly requests correction.

### 2. Provide a stable command-line contract

The CLI should be usable from shell scripts without parsing Elixir exception
text. Successful and failed invocations need stable JSON envelopes, documented
exit statuses, and a strict stdout/stderr policy. For example:

```json
{
  "ok": false,
  "error": {
    "phase": "manifest",
    "code": "invalid_limit",
    "path": "/limits/evaluation_timeout_ms",
    "file": "ptc.json",
    "message": "requested value exceeds the installed ceiling",
    "notes": ["requested: 60000", "ceiling: 30000"]
  }
}
```

Add focused commands:

```console
ptc init
ptc validate ptc.json
ptc run ptc.json --input input.json --trace trace.jsonl
ptc repl --manifest ptc.json
ptc models
ptc doctor
```

Because this is a 0.x library, rename the misleading `--mission` input override
to `--input` rather than carrying a compatibility alias. `ptc models` should
replace the currently unactionable error advice to use `--list-models`.
`ptc doctor` should verify runtime versions, credentials, model configuration,
manifest-relative files, and optional viewer availability without exposing
secret values.

### 3. Separate installed ceilings from requested limits

Keep all current hard bounds, but distinguish two sources:

- **installed ceilings**, controlled by the embedding host or deployment; and
- **requested limits**, supplied by a manifest and always less than or equal to
  those ceilings.

Defaults should be practical for the selected workflow profile. A deterministic
data transform can retain short evaluation limits, while an agent workflow may
need a longer bounded run and provider deadline. The public result should show
both requested limits and the usage that was charged against them.

This change must preserve the single atomic owner operations used for leases,
usage, closure, and late-result rejection.

### 4. Make REPL execution match normal execution

The REPL should reuse the normal workflow tool-assembly path, including
reserved Kernel tools for capability listing, descriptions, usage, remaining
budget, subordinate evaluation, and annotations. It should distinguish the
short Lisp evaluation budget from the longer bounded provider-call deadline.

Parity tests should load one manifest and assert that `ptc.run` and `ptc.repl`
see the same workflow libraries, capabilities, schemas, and confinement. The
REPL may retain session memory and history, but that is the only intentional
semantic difference.

### 5. Improve model reliability at the boundary

Generate the agent's authority inventory from the frozen run configuration,
not from domain-specific prompt text. Each visible capability needs at least:

- public name and bounded description;
- argument and result schema;
- environment and model-visibility classification;
- relevant size, call, and timeout budget.

Carry structured-output schema and safe allowlisted model options through the
LLM adapter. Aggregate token and cost metadata when providers supply it, and
allow deployments to enforce token or cost ceilings in addition to Kernel call
ceilings.

The correction loop should preserve a provider-valid assistant/tool/result
history, include bounded error code, message, and source location, and use an
explicit retry/backoff policy. Result validation should be a reusable runtime
facility rather than prompt wording in each example.

One provider name and one selected model per workflow are sufficient for the
next milestone. Multi-model routing can wait until the single-model path is
operationally clear.

### 6. Add shared host access and versioned prelude workspaces

Introduce a small host-only contract for principals, exact resource grants,
bounds, request correlation, and redacted audit records. Keep operation
semantics in separate services: TraceLog remains the trace query owner, a new
prelude workspace service owns immutable revisions and candidates, and the
Viewer remains an authenticated adapter rather than an authority source.

Models receive only explicitly compiled capabilities delegated to their run.
Humans receive only grants resolved from their authenticated host session.
Neither the manifest nor browser can select a role, path, endpoint, credential,
or grant. Prelude edits create optimistic-concurrency candidates; validation,
compilation, and promotion are distinct operations, and promotion affects only
later rebuilt frozen environments.

The exact structs, schemas, service operations, implementation slices, test
gates, and examples are defined in
[`host-access-and-prelude-workspaces.md`](host-access-and-prelude-workspaces.md).
Its H0 contract is also the authorization dependency for connector sources.

### 7. Add one constrained external capability route

After trusted libraries, schemas, diagnostics, and ceilings are in place, add
one administrator-installed route to external tools. An MCP client is the most
natural first option for the intended audience; an allowlisted HTTP/OpenAPI
bridge is also viable.

The proposed source contract, security boundary, usage examples, and staged
acceptance tests are defined in the
[`capability-connectors.md`](capability-connectors.md) future plan.

The bridge must preserve Kernel authority rules:

- the deployment installs servers, base URLs, credentials, and network
  allowlists;
- the manifest selects only public capability names;
- schemas, timeout, maximum response size, quota, and model visibility are
  frozen before the run;
- credentials never enter Lisp data, prompts, results, or normal traces;
- manifests cannot execute host code, launch arbitrary commands, or choose an
  arbitrary network destination.

Do not reintroduce the deleted broad tool platform merely to gain connectivity.
Prove one narrow bridge end to end first.

### 8. Split operational traces from diagnostic transcripts

Keep the canonical normal trace sanitized. Its current omission of sensitive
prompts, model responses, arguments, results, and generated source is a useful
security default, not a bug.

Add a separate opt-in diagnostic transcript with explicit retention,
redaction, file permissions, size limits, and viewer labeling. Persist events
through a host-owned or durable sink while a run is active so a VM crash does
not erase all progress. Directory discovery should report and quarantine bad
files individually while continuing to expose healthy traces.

Live progress and streaming can build on the event-consumer boundary later;
they are not required to stabilize the first CLI product.

The current viewer browser pass covers run discovery, status and timestamp
badges, sanitized-trace messaging, metrics, prelude cards, paired evaluations,
capability calls, annotations, raw canonical events, error runs, navigation,
and private-trace hiding. Pagination remains a specific verification gap:
create a validator-accepted run with more than 100 events and confirm in a real
browser that repeated `Load more events` actions preserve order, add no
duplicates, retain the current run, and stop cleanly at the final cursor.

### 9. Package the user journey

Once the manifest and CLI contracts are stable, publish a breaking 0.x release
that represents the new Kernel product rather than the deleted architecture.
Provide at least one standalone installation path: an OTP release/native CLI
archive or a supported container image. Document exact supported OTP versions,
configuration, upgrades, and trace storage.

Package the viewer as a production artifact instead of depending on the sibling
project through development-only wiring. A later service frontend can add job
submission, cancellation, concurrency control, and durable results without
changing the Kernel authority model.

### 10. Define the supported PTC-Clojure profile

Continue treating Clojure compatibility as the default, subject to sandbox
safety and recoverable signal values. Product docs should nevertheless name a
specific supported profile and link to the
[conformance report](../../conformance/index.md). Prioritize silent wrong-result
gaps and common collection/namespace operations before increasing the raw
function count.

Examples must stay within the advertised profile. Missing or intentionally
different behavior should fail clearly and link to the relevant conformance
note where possible.

## Prioritized roadmap

### Phase 0: close immediate correctness and DX gaps

- Keep the entropy-based default run IDs and add a subprocess regression that
  proves repeated CLI processes can share a trace directory.
- Isolate malformed trace files during directory discovery.
- Introduce stable machine-readable CLI errors with phase, code, JSON path,
  file, message, and bounded notes.
- Correct stale CLI advice and documentation where current behavior differs.
- Browser-test viewer pagination with a valid run containing more than 100
  canonical events.

Exit gate: repeated subprocess runs persist and load independently, a bad
trace does not hide good traces, and common invalid manifests have asserted
JSON diagnostics and exit statuses. Viewer pagination has a recorded browser
pass in addition to its API coverage.

### Phase 1: manifest-first productization

- Add `ptc init`, `ptc validate`, `ptc models`, and `ptc doctor` equivalents.
- Add trusted manifest library references and migrate the tutorial to the
  shipped `agent.core` implementation.
- Add manifest input/output schemas.
- Rename `--mission` to `--input`.
- Separate installed ceilings from manifest-requested limits.
- Make REPL tool assembly and timeouts match normal workflow execution.
- Add full scripted CLI and optional live DeepSeek manifest-agent tests.

Exit gate: a developer can create, validate, run, debug, and trace a bounded
agent from JSON, PTC-Lisp, and shell commands without editing Elixir.

### Phase 2: model reliability

- Generate mission export and capability inventories with schemas.
- Add structured model output and bounded model options.
- Track token/cost metadata and enforce configured budgets where available.
- Preserve proper correction history, bounded diagnostics, and retry policy.
- Improve source spans through compile and runtime errors.

Exit gate: scripted protocol failures recover deterministically, schema-invalid
terminal output cannot report success, and the supported DeepSeek E2E agent
completes the documented file workflow within declared budgets.

### Phase 3: authenticated host resources and prelude workspaces

- Implement the H0 shared principal, exact-resource grant, bounds, scoped
  authorization, error, and audit contract.
- Prove it by routing model and Viewer trace reads through the same TraceLog
  service without changing canonical event semantics.
- Add separately authorized exact generated-program/prelude source views.
- Add immutable prelude revisions, candidate authoring, validation, compilation,
  atomic promotion, explicit model capabilities, and authenticated Viewer UI in
  the slices defined by the host-access plan.

Exit gate: an authenticated human and delegated model receive equivalent
domain results for equivalent grants, sensitive source requires a distinct
grant, concurrent edits cannot overwrite each other, and promotion creates a
new revision used only by later frozen environments.

### Phase 4: capability ecosystem

- Implement the staged
  [capability connector plan](capability-connectors.md), beginning with one safe
  administrator-installed MCP Streamable HTTP tools connector.
- Reuse the H0 host-access types and audit context while keeping discovery,
  transport, credentials, snapshots, sessions, and leases connector-owned.
- Freeze schemas, credentials policy, network policy, quotas, and visibility
  into the run configuration.
- Add contract tests for timeout, cancellation, late results, oversized
  responses, credential redaction, and destination confinement.

Exit gate: a manifest can select a real external tool without adding Elixir or
gaining ambient host/network authority.

Connector C0 may begin as soon as H0 is stable; it need not wait for prelude or
Viewer slices.

### Phase 5: distribution and operation

- Publish a Kernel-era breaking release and standalone CLI/container.
- Package the viewer for production use.
- Add active durable event persistence and operational health checks.
- Add a service frontend only if deployments need jobs, cancellation, or
  concurrency beyond the CLI.

Exit gate: a clean environment can install the documented artifact, run the
tutorial, inspect its trace, and remove all state using only published
instructions.

## Release-readiness checklist

The Kernel is usable as the intended non-Elixir product when all of the
following are true:

- A new user can start from a small JSON manifest and PTC-Lisp component rather
  than an Elixir project.
- Trusted shipped libraries are selectable and versioned without copying their
  source.
- Validation identifies the exact bad file/field and produces stable
  machine-readable output.
- Installed ceilings remain authoritative while manifests can request
  practical bounded model budgets.
- Run and REPL expose the same authority and capability metadata.
- Inputs and terminal outputs can be schema-validated.
- One supported external capability route works without arbitrary code or
  network authority.
- A complete scripted agent journey runs in normal CI, with a small optional
  live DeepSeek journey run manually or on a scheduled credentialed job.
- Normal traces remain sanitized, diagnostic transcripts are explicitly
  opt-in, and damaged files do not poison trace discovery.
- Authenticated host grants are shared across adapters without making the
  Viewer or manifest an authority source.
- Human or model prelude changes remain candidates until separately authorized
  atomic promotion creates an immutable revision for a later environment.
- A published artifact installs and runs without a repository checkout.
- The advertised PTC-Clojure profile and all known semantic gaps are easy to
  find.

## Guardrails and deferred work

The following principles should remain intact while improving usability:

- Do not weaken workflow/mission separation, immutable bundles, atomic owner
  operations, hard limits, late-result rejection, path confinement, or the
  sanitized canonical trace.
- Do not allow a manifest to register native callbacks, choose arbitrary
  network destinations, read credentials, or launch commands.
- Do not restore the legacy evaluator, SubAgent, role/prelude runtime, or broad
  tool platform as compatibility layers. This is a 0.x clean-path replacement.
- Do not add shell, write, or unrestricted network capabilities before trusted
  library resolution, schemas, diagnostics, and deployment ceilings are
  established.
- Keep prompts domain-blind. Capability descriptions may describe their own
  tools, but system/agent prompts must not encode benchmark answers or domains.

Streaming model responses, interactive Viewer Lab features, multi-model
routing, chat lifecycle management, concurrent mission evaluation, live bundle
mutation, and broad Clojure coverage are useful later improvements. None should
block the manifest-first milestone.

## Related documents

- [Kernel maintainer guide](../../guides/kernel-maintainer.md) — current
  authority, lifecycle, ownership, and implementation map; exact API details
  live in the `PtcRunner.Kernel.*` module documentation.
- [`tracelog-contract.md`](tracelog-contract.md) — canonical event and source
  contract.
- [`host-access-and-prelude-workspaces.md`](host-access-and-prelude-workspaces.md)
  — future shared authorization, TraceLog/Viewer, and versioned prelude plan.
- [`capability-connectors.md`](capability-connectors.md) — future external
  capability source and inbound frontend plan.
- [Kernel tutorial](../../guides/kernel-tutorial.md) — current runnable user
  journey.
- [Kernel REPL](../../guides/kernel-repl.md) — current interactive interface.
- [PTC-Lisp conformance](../../conformance/index.md) — audited language
  coverage and known gaps.
