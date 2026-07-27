# Lisp Kernel product readiness

**Status:** active roadmap; reviewed 2026-07-27.

The bounded Kernel, manifest-authored application path, host-installed MCP and
LLM sources, classified artifacts, input/result contracts, native trace
snapshots, and isolated candidate-evaluation flow are implemented. Their
durable contracts live in the owning module documentation and implemented
guides.

This plan contains only the remaining work needed to make that runtime
straightforward to install, script, diagnose, and operate without Elixir
expertise.

## Current limitations

| Priority | Area | Current limitation | Consequence |
| --- | --- | --- | --- |
| P0 | CLI diagnostics | `mix ptc.run` still reports many failures through `Mix.raise/1` and inspected Elixir terms. | Scripts cannot reliably identify the failing phase, file, field, or repair. |
| P1 | Command-line workflow | The repository lacks focused initialize, validate, model-list, and doctor commands, and the input override is still named `--mission`. | First-time users must know internal terminology and infer setup failures from the generic runner. |
| P1 | Model protocol | Host-installed LLMs freeze bounded sampling options, but structured-output schema, reasoning controls, an explicit provider timeout, and enforceable token or cost ceilings remain outside the public configuration surface. | Deployments cannot yet express richer model contracts or complete operational budgets. |
| P1 | Trace operation | A malformed, duplicate, or oversized trace can make a directory source fail as a whole, and trace persistence remains post-run. | One damaged file can hide healthy runs and a crash can lose buffered events. |
| P1 | Distribution | The user workflow assumes a source checkout, Erlang/Elixir, and Mix; the Viewer is a development path dependency. | Installation and deployment remain too heavy for the intended non-Elixir audience. |
| P1 | End-to-end evidence | Packaged-install, private-sink/loss, real multi-page Viewer, and complete shell-driven application journeys remain absent. | Large-artifact, packaging, and cross-command regressions can escape normal gates. |
| P2 | Viewer pagination | Cursor APIs, accumulation, and partial labeling have focused tests, but no valid run above 100 events has been exercised through repeated browser pagination. | Ordering, duplication, or final-cursor defects can remain despite API coverage. |
| P2 | Source diagnostics | Parser, compiler, and runtime failures do not consistently retain precise source spans across every boundary. | Larger bundles take longer to repair. |
| P2 | Language expectations | PTC-Lisp is Clojure-oriented rather than a full Clojure implementation. | Familiar-looking programs can encounter unsupported functions or intentional recoverable-signal differences. |
| P2 | Reference quality | Some generated function-reference entries still have minimal descriptions, and the implemented MCP-era application journey is spread across several guides and examples. | First-time authors must assemble more context than necessary. |

## 1. Stabilize the command-line contract

Successful and failed invocations need stable JSON envelopes, documented exit
statuses, and a strict stdout/stderr policy. A failure should identify at
least:

- phase and stable code;
- JSON path and source file when applicable;
- bounded human-readable message and notes; and
- whether any provider activity occurred.

Add focused command-line entry points equivalent to:

```console
ptc init
ptc validate ptc.json
ptc run ptc.json --input input.json --trace trace.jsonl
ptc repl --manifest ptc.json
ptc models
ptc doctor
```

Because this is a 0.x library, rename `--mission` to `--input` without a
compatibility alias. `ptc doctor` should verify runtime versions, credentials,
model configuration, manifest-relative files, launcher availability, and
optional Viewer availability without exposing secret values.

Keep the entropy-based default run identifiers and add a real subprocess
regression proving that repeated CLI processes can publish into one trace
directory without collisions.

**Exit gate:** common invalid manifests have asserted JSON diagnostics and exit
statuses; validation and doctor commands fail before provider activity where
possible; repeated subprocess runs persist and load independently.

## 2. Complete the model boundary

Carry structured-output schema and a closed set of reasoning/sampling options
through the LLM adapter. Add an explicit provider timeout distinct from the
overall run and capability budgets.

Normalize token and cost metadata when a provider supplies it, and allow an
installation to enforce corresponding ceilings. Provider-dependent missing
metadata must remain explicit rather than being inferred.

Improve source locations through parse, compile, generated-program, and
runtime errors. Model-visible feedback must remain bounded and safe, while
exact generated source and provider exchanges remain available only through
explicit private inspection authority.

**Exit gate:** a host can request and validate structured model output,
provider work has an explicit deadline, available usage is charged against
installed ceilings, and a generated-program failure identifies the closest
safe source location.

## 3. Harden trace and Viewer operation

Isolate malformed trace files during directory discovery so one bad artifact
does not hide healthy runs. Define an active persistence strategy that
preserves bounded canonical events during abnormal host termination.

Complete the realistic private-sink, overflow, pagination, and cache-usage
journeys in
[`real-flow-e2e-hardening.md`](real-flow-e2e-hardening.md). In particular,
exercise a validator-accepted run with more than 100 events through the actual
browser interaction and prove ordering, deduplication, current-run retention,
final-cursor behavior, and explicit partial labeling.

**Exit gate:** damaged traces are isolated, loss is visible, and one realistic
large run passes the complete trace-to-browser path.

## 4. Package the user journey

Publish a breaking 0.x release representing the current Kernel product. Supply
at least one standalone installation path: an OTP release/native CLI archive
or a supported container image. Document supported OTP versions,
configuration, upgrades, trace storage, and complete removal.

Package the Viewer as a production artifact rather than depending on the
sibling project through development-only wiring. Add operational health checks
for the packaged runtime and its optional launcher.

A service frontend may add job submission, cancellation, concurrency control,
and durable results only when deployments require it; it is not a prerequisite
for the standalone product.

**Exit gate:** a clean environment can install published artifacts, run the
documented application journey, inspect its trace, and remove all state
without a repository checkout.

## 5. Keep the supported PTC-Clojure profile explicit

Clojure compatibility remains the default, subject to sandbox safety and
recoverable signal values. Product documentation should name the supported
profile and link to the generated
[conformance report](../../conformance/index.md).

Prioritize silent wrong-result gaps and common collection or namespace
operations before increasing the raw function count. Examples must stay
within the advertised profile, and intentional differences should fail
clearly and point to their conformance rationale.

## Release-readiness checklist

The Kernel is ready for its intended non-Elixir product boundary when:

- a new user can initialize, validate, run, and diagnose an application from
  published artifacts;
- failures have stable machine-readable envelopes and exit statuses;
- model deadlines, structured results, and available usage ceilings are
  enforceable;
- damaged traces do not poison discovery and realistic loss/pagination
  journeys pass;
- the Viewer and optional launcher ship as supported artifacts; and
- the advertised PTC-Clojure profile and known semantic gaps are easy to find.

## Guardrails and deferred work

- Do not weaken workflow/mission separation, immutable bundles, atomic owner
  operations, hard limits, late-result rejection, path confinement, or
  sanitized canonical traces.
- Do not allow manifests to register callbacks, choose endpoints or commands,
  read credentials, or expand host-installed authority.
- Keep prompts domain-blind.
- Keep exact provider exchanges, generated source, and private values out of
  normal traces and public results.
- Do not restore deleted evaluators, providers, or compatibility layers.

Streaming responses, multi-model routing, chat lifecycle management,
concurrent mission evaluation, live bundle mutation, broad Clojure coverage,
MCP Tasks, writes, OAuth, shared catalog caching, authenticated host IAM, and
inbound service frontends require demonstrated demand and separate plans.

## Related documents

- [Kernel maintainer guide](../../guides/kernel-maintainer.md) — implemented
  authority, lifecycle, ownership, and code map.
- [Manifests and capabilities](../../guides/manifests-and-capabilities.md) —
  current host installation, manifest, classification, and contract behavior.
- [Running and debugging](../../guides/running-and-debugging.md) — current CLI,
  trace, inspection, and failure workflow.
- [Building agents](../../guides/building-agents.md) — current agent and model
  composition guidance.
- [Getting started](../../guides/getting-started.md) — runnable examples.
- [TraceLog contract](../../trace-log-contract.md) — canonical event and source
  contract.
- [PTC-Lisp conformance](../../conformance/index.md) — audited language
  coverage and known gaps.
- [Real-flow E2E hardening](real-flow-e2e-hardening.md) — remaining
  private-sink, overflow, pagination, and cache-usage journeys.
