# Minimal Programmable Kernel — Migration Plan

**Status:** proposed implementation sequence. Governed by
[`kernel-contract.md`](kernel-contract.md).

**Implementation branch:** `exp/minimal-kernel`, created from
`exp/lisp-kernel` when implementation begins.

## Method

Use a clean vertical slice inside this repository, then delete the old product
aggressively.

Do not:

- copy the project into a fresh repository;
- refactor every existing SubAgent/Kernel abstraction into the new design;
- create a public V2 API or SubAgent compatibility facade;
- move deleted code into `legacy/`;
- begin deletion before the replacement path owns the retained behavior.

Retain the proven Lisp/sandbox/conformance foundation. Build the new Kernel
contract against it. Extract an old mechanism only when the clean path reaches
a demonstrated need. Git history is the archive.

Temporary internal modules are allowed during the cutover only with an explicit
removal condition and no public documentation.

## Execution workflow: local commits, no PR

Implementation is performed as a sequence of intentional local commits on
`exp/minimal-kernel`, created from the approved `exp/lisp-kernel` base when work
begins.

Do not open a pull request or require human review for the implementation
series. Do not push unless explicitly requested. Preserve reviewability through
small vertical commits, Conventional Commit subjects, recorded verification,
and a final repository-wide Codex review.

Each commit must:

- have one coherent contract/migration objective;
- update implementation, tests, inventory, and relevant docs together;
- avoid compatibility shims and unrelated cleanup;
- pass focused deterministic tests for the changed boundary;
- pass `mix precommit` before commit, as required by `AGENTS.md`;
- record important verification and any intentionally deferred finding in the
  commit body for non-trivial changes.

Run `mix prepush` before any eventual push, even when no PR is planned.

### DeepSeek E2E gate

Use the repository's `deepseek` model alias for live protocol and workflow
verification. It currently resolves through the model registry to an OpenRouter
model and requires `OPENROUTER_API_KEY`.

Canonical command shape:

```console
PTC_TEST_MODEL=deepseek mix test --include e2e
```

Prefer a focused new-Kernel E2E file while the old SubAgent/evaluator suite
still exists, then run the complete retained E2E suite once cutover is complete.

Live-model E2E complements rather than replaces deterministic tests. It cannot
reliably prove capability confinement, owner-process atomicity, deadlines,
rollback, bounds, cleanup, or exact failure classification. Those remain
deterministic contract tests.

Run DeepSeek E2E:

- after a commit that changes `llm/request`, `agent.native`, `agent.core`,
  feedback/retry, model-visible inventories, manifest model selection, or the
  end-to-end Kernel workflow;
- at every architectural milestone after generic LLM integration exists;
- before public cutover;
- after deletion of the old agent path;
- as part of the final review gate.

For early capability/environment/state commits that have no LLM path, focused
deterministic tests plus `mix precommit` are the meaningful gate. Do not add
artificial LLM calls merely so every commit has a live test.

For every live run, retain or report:

- requested alias (`deepseek`);
- resolved model ID and provider;
- exact command and commit SHA;
- pass/fail/skip result;
- trace/private-transcript location when produced;
- whether a failure is product, provider, credentials, or infrastructure.

Provider/network failures are not silently treated as product success. A
skipped run due to missing credentials is recorded as skipped, not passed.

### Codex goal lifecycle

Create a Codex goal only when implementation begins and the user explicitly
requests execution. Do not create it during plan editing. Do not assign a token
budget unless the user explicitly asks for one.

Recommended goal objective:

```text
Implement the approved minimal programmable Kernel contract on
exp/minimal-kernel as a verified multi-commit series, complete the migration and
deletion inventory, run deterministic and DeepSeek E2E gates, perform a final
independent repository-wide review, fix all actionable findings, and finish
with precommit/prepush/E2E green and the inventory closed.
```

The goal remains active through implementation, final review, remediation, and
the last verification run. Do not mark it complete merely because feature code
or deletion waves are finished.

An alternative is two explicit goals—a completed implementation goal followed
by a fresh review/remediation goal—but an unfinished goal must be completed
before another is created. The single objective above better guarantees that
review findings are fixed before declaring the overall work achieved.

The goal tracks persistence and completion; it is not itself an independent
review method. The final review must invoke an independent Codex CLI review
using the repository's `codex-review` workflow or an equivalent fresh review
context.

### Ready-to-use goal prompt

Use a prompt like the following when the planning documents have been approved
and committed on `exp/lisp-kernel`. This prompt explicitly authorizes the
implementation branch and commits; it does not authorize a push or PR.

```text
Create a Codex goal for the complete minimal programmable Kernel migration and
then execute it autonomously to completion. Do not set a token budget.

Repository:
/Users/andreasronge/projects/ptc_runner-lisp-kernel

Authoritative documents:
- docs/plans/lisp-kernel/kernel-contract.md
- docs/plans/lisp-kernel/tracelog-contract.md
- docs/plans/lisp-kernel/kernel-migration.md
- docs/plans/lisp-kernel/kernel-inventory.md
- docs/plans/lisp-kernel/private-experiment-transcripts.md
- AGENTS.md

Before changing runtime code:
1. Verify the planning documents are committed and the current integration
   branch is exp/lisp-kernel.
2. Record the exact base commit SHA.
3. Create exp/minimal-kernel from that SHA and perform all implementation work
   there.
4. Resolve any remaining normative open decisions in kernel-contract.md before
   implementing the affected behavior. Do not silently choose semantics that
   contradict or extend the contract.

Implement the migration in the vertical slices and order defined by
kernel-migration.md. Treat kernel-inventory.md as a live deletion checklist.
Keep the proven Lisp, sandbox, conformance, immutable-prelude, TraceLog, and
ptc_viewer foundations. Build the clean Kernel path before deleting its old
owners. Do not add compatibility shims, a public V2 API, a legacy directory, or
parallel old/new product surfaces.

Use multiple small, coherent local commits with Conventional Commit subjects.
For every non-trivial commit:
- add or update integration/conformance tests first where the change is a bug
  fix;
- update implementation, docs, and inventory together;
- run focused deterministic tests;
- run mix precommit before committing;
- include a short commit body describing the change and verification.

Do not open a pull request. Do not push. Do not require human review. Preserve
the user's unrelated working-tree changes and do not use destructive Git
commands.

Use the deepseek model alias for live E2E verification when an LLM-capable path
exists:

  PTC_TEST_MODEL=deepseek mix test --include e2e

Run focused DeepSeek E2E after changes to llm/request, agent.native, agent.core,
feedback/retry, model-visible inventories, manifest model selection, and the
end-to-end Kernel workflow; at architectural milestones; before public cutover;
after deleting the old agent path; and during final verification. Record the
requested alias, resolved model/provider, command, commit SHA, result, and trace
location. Missing credentials or provider failures are skips/infrastructure
failures, not product passes. Do not use live E2E as a substitute for
deterministic confinement, limits, state, timeout, rollback, and cleanup tests.

Do not delete or substantially rewrite the current evaluator until the private
transcript work is integrated, re-homed, or explicitly superseded as required
by the migration plan. Keep ptc_viewer and the TraceLog contract. Keep
ptc.install_babashka while retained conformance tests use it.

After all implementation and deletion slices are complete, do not complete the
goal yet. Perform the final review gate from kernel-migration.md:
1. Review the complete recorded-base-to-HEAD diff and repository using an
   independent Codex CLI review through the codex-review workflow or an
   equivalent fresh review context.
2. Audit every normative clause in kernel-contract.md and
   tracelog-contract.md against source and tests.
3. Audit structural workflow/mission confinement, capability dispatch and
   timeouts, owner-process atomicity, late-result invalidation, transactional
   evaluation memory, event sinks, TraceLog grants/bounds, duplication, orphan
   modules, dependencies, package contents, docs, Mix tasks, CI, and every
   inventory row.
4. Run coverage and deterministic benchmark checks.
5. Run mix precommit, mix prepush, and the retained DeepSeek E2E suite.
6. Fix every actionable finding in explicit review-fix commits.
7. Re-run an independent verification of the fixes and all final gates.

Mark the Codex goal complete only when the contract is implemented, migration
and deletions are complete, no actionable review finding remains, the temporary
inventory is closed or deleted, and deterministic, precommit, prepush, viewer,
conformance, and DeepSeek E2E gates are green. If genuinely blocked, exhaust
safe in-scope alternatives and report the exact blocker without weakening the
contract or silently skipping required verification.
```

The goal objective created from that prompt should cover implementation,
deletion, final review, remediation, and final verification as one terminal
outcome. Do not complete an implementation-only objective and leave review as
an informal follow-up.

### Final review gate

After all planned implementation and deletion commits, but before completing
the goal:

1. Freeze the review range from the recorded base SHA on `exp/lisp-kernel` to
   the final implementation HEAD.
2. Run an independent Codex review over the complete repository and diff.
3. Audit every normative clause in `kernel-contract.md` and
   `tracelog-contract.md` against source and integration tests.
4. Audit structural workflow/mission confinement, capability result/timeout
   semantics, owner-process atomicity, late-result invalidation, evaluation
   memory rollback, event-sink failure policies, and path/source grants.
5. Audit duplication, orphan modules, dependencies, package contents, docs,
   Mix tasks, CI, and every row in `kernel-inventory.md`.
6. Run coverage and deterministic benchmark regression checks.
7. Run `mix precommit`, `mix prepush`, and the retained DeepSeek E2E suite.
8. Commit fixes as one or more explicit review-fix commits.
9. Re-run the independent review on the fixes or request a focused verification
   of every prior actionable finding.
10. Complete the goal only when no actionable finding remains, gates are green,
    and the temporary inventory is closed or deleted.

The absence of a PR or human review does not relax repository safety rules,
test-first bug fixes, documentation updates, or commit verification.

## Retained mechanisms and extraction seams

Start narrowly with:

- parser, atom-safe AST values, format, and Clojure conformance as foundation;
- analyzer/evaluator/runtime semantics extracted behind a neutral Kernel
  evaluation context, removing agent, upstream, journal, and public-Step policy;
- sandbox process, heap/time/source, worker-limit, and cleanup mechanisms
  extracted behind a neutral execution interface;
- native continuation memory and persistent definitions;
- protected namespace, export, and `requires` discovery extracted from the
  prelude compiler after removing its SubAgent signature and upstream coupling;
- existing bundle provenance and source composition as evidence for the new
  component-ID DAG, not as the target bundle API;
- current tool dispatch as evidence only; do not carry `PtcRunner.Tool` exposure,
  caching, SubAgent type, or private-authorization policy into Capability;
- canonical event data and minimum TraceLog storage/query primitives;
- `ptc_viewer`, coordinated with its active work;
- Babashka installer and conformance tooling.

Existing code is evidence, not the target API. In particular, the current
`PtcRunner.Kernel` hard-codes the policy that moves to Lisp, its error path may
commit candidate evaluation memory, and `StateHandle` owns only leased memory,
not the complete target RunState.

## Implementation slices

Each slice is independently reviewable and passes focused tests. Run
`mix precommit` before committing.

### 0. Freeze planning inputs

- Review and approve `kernel-contract.md`.
- Populate `kernel-inventory.md` with every root module/top-level directory.
- Approve the proposed core resolutions in `kernel-contract.md` and record any
  later-slice schema details still intentionally deferred by the spike.
- Record the current focused test and benchmark baselines.
- Do not write runtime code or start deletion until this slice is complete.

### 1. Core value and owner primitives

Add responsibilities equivalent to:

- `Kernel.Capability`;
- structurally distinct `Kernel.WorkflowEnvironment` and
  `Kernel.MissionEnvironment`;
- `Kernel.Limits`;
- `Kernel.RunState`;
- `Kernel.Dispatcher`;
- the host-only provider-registry interface;
- the minimum canonical event and bounded sink primitive;
- `Kernel.Result` and `Kernel.Error`.

These are responsibilities first; create separate modules only where the code
benefits.

No LLM, manifest, REPL, viewer, or deletion work belongs in this slice.

Focused tests cover:

- environment construction and rejection of conflicts;
- atomic total/per-name capability reservation;
- atomic subordinate-evaluation reservation;
- deadline snapshots and closure;
- callback raises, exits, hangs, invalid returns, and oversized results;
- explicit provider-task heap and live-task ceilings;
- per-call timeout under the remaining deadline;
- late-result invalidation after timeout/close;
- bounded uniform capability envelopes;
- evaluation-memory commit/rollback and retained-size caps;
- normal lossy versus private fail-closed event behavior;
- one deterministic in-memory grant-bearing read capability proving that grant
  objects remain host-held and cannot be forged from Lisp;
- bounded usage projection.

Provider callbacks run in monitored, explicitly heap-limited tasks. External
cancellation is best effort; late results must never re-enter Lisp or mutate run
state. Tests distinguish contained provider faults from malicious host extension
behavior outside the Kernel threat model.

The first local implementation commit should normally stop here.

### 2. Component-ID bundle compilation

Build `compile_bundle/1` over the retained compiler/bundle mechanisms:

- explicit closed component set;
- component-ID dependency graph;
- deterministic topological ordering with component-ID tie-breaking;
- missing dependency and cycle errors;
- duplicate component ID, namespace, and export conflict errors;
- recorded `requires` metadata followed by separate environment-assembly
  validation against the workflow or mission capability map;
- frozen provenance and hashes;
- component/edge/source/time/heap/artifact/diagnostic limits;
- atomic failure with bounded diagnostics.

Do not add stores, roles, fetching, version solving, or runtime selection.

### 3. Small outer workflow

Run:

```clojure
(return (+ 40 2))
```

through the new entry-expression path, workflow environment, hard limits,
run-owned state, event sink, and public result/error algebra.

Cover start/stop events, workflow failure, deadline exhaustion, heap/source
limits, event bounding, and sink policies.

### 4. Mission confinement and subordinate evaluation

Add reserved workflow-only `kernel-eval`.

The first architectural milestone is two sequential evaluations such as:

```clojure
(tool/kernel-eval {:kind :source :source "(def x 40)"})
(tool/kernel-eval {:kind :source :source "(return (+ x 2))"})
```

Prove:

- mission capability access succeeds inside subordinate evaluation;
- workflow capability access succeeds only in the outer workflow;
- subordinate access to workflow capabilities, `kernel-eval`, runtime control,
  and privileged annotations fails;
- `kernel-eval` receives only `%MissionEnvironment{}` and has no merge path;
- definitions persist sequentially;
- failed and oversized candidates preserve prior evaluation memory;
- a concurrent evaluation receives recoverable `:busy` without consuming an
  evaluation budget or queueing past the deadline;
- all subordinate outcomes are bounded and recoverable by the workflow.

Prefer structural function signatures and tests over checking confinement only
through symbol visibility.

### 5. Opaque static Program values

After string-based `kernel-eval` confinement works, add the narrow `program`
special form and Lisp helpers:

```clojure
(kernel/eval
  (program
    (return (+ data/x data/y))))

(kernel/eval-source dynamic-source)
```

This slice includes:

- parser/analyzer support for capturing forms without workflow evaluation or
  symbol/`requires` resolution;
- one opaque bounded Program representation with origin/span when known, byte
  size, and digest;
- discriminated `:embedded` and `:source` requests to the same reserved
  `kernel-eval` capability;
- no interpolation, full quote, quasiquote, macros, AST walking, or general
  `eval`;
- identical mission confinement, current evaluation memory, limits, outcomes,
  and tracing for embedded and dynamic source;
- bounded opaque public/debug projection;
- tests proving workflow locals/capabilities are not captured and earlier
  subordinate definitions can be referenced.

Accurate inner source mapping depends on the parser/analyzer span workstream.
Do not advertise model-editable preludes until complete locations exist, but do
not block the earlier string-based confinement milestone on spans.

### 6. First ordinary mission capability

Adapt one deterministic read-only file fixture using the standard capability
contract and a small `fs` prelude.

Prove argument validation, explicit root grants, path confinement, call/result
limits, uniform errors, environment-local discovery, and no ambient filesystem
access.

Do not retain a full example application for this proof.

### 7. Generic LLM workflow capability and Lisp agent libraries

Expose provider-neutral `llm/request` as an ordinary configured workflow
capability. The host adapter owns credentials, transport normalization,
ceilings, timeout/cancellation, accounting, and fault containment.

Port policy to shipped Lisp libraries:

- `agent.native` — `run_ptc_lisp` schema and action validation;
- `agent.core` — loop and message history;
- `agent.feedback` — correction policy;
- `agent.retry` — retry decisions;
- `workflow.event` — annotations;
- `result` — uniform result helpers.

Delete `Kernel.Action` after parity is proven; do not generalize it.

Scripted LLM integration tests cover exactly one tool call, mixed prose,
multiple/malformed calls, corrected evaluation, explicit failure, generic
capability quotas, and provider failures. These are agent-library tests, not
universal Kernel protocol tests.

### 8. Manifest and shared run builder

Add one strict versioned manifest loader and provider registry:

- reject unknown keys and unsupported versions;
- resolve source/input paths relative to the manifest;
- enforce destination-specific safety rules;
- compile separate workflow/mission bundles;
- resolve registered providers without arbitrary Elixir module/function names;
- construct frozen environments and normalized hard limits;
- generate the bounded qualified entry expression;
- call the same Kernel API used by embedding.

Test deterministic replay of the same manifest/input and safe rejection of
authority expansion.

### 9. CLI, REPL, TraceLog, and viewer

- Add thin `mix ptc.run MANIFEST [--mission PATH]`.
- Simplify `mix ptc.repl` to direct PTC-Lisp evaluation, persistent history,
  scripts, basic bundle support, optional shared manifest grants, and canonical
  traces.
- Remove REPL Session/SubAgent formatting, upstream, catalog, and special
  log-prelude paths.
- Preserve TraceLog run discovery, run metadata, turns, counters, sanitization,
  source-scoped grants, and swappable `log` prelude.
- Implement [`tracelog-contract.md`](tracelog-contract.md), including
  append-only JSONL, bounded memory sinks, deterministic directory loading,
  rebuildable indexes, required metadata, filtering, pagination, and aggregate
  source/result limits.
- Align canonical events/private transcript capture with `ptc_viewer`.
- Keep the viewer read-only in this slice; plan an interactive Lab separately.

### 10. Public cutover

- Move retained internal callers to the new Kernel.
- Run `mix xref graph` and a targeted source search proving that the new Kernel,
  Lisp libraries, sandbox interface, compiler, and provider registry no longer
  depend on any SubAgent/upstream/role-store/public-Step type scheduled for
  deletion.
- Replace the experimental public Kernel at one explicit cutover.
- Publish only the contract result/error/environment/config surface.
- Delete temporary implementation namespaces.
- Do not ship parallel old/new Kernel or SubAgent facades.

### 11. Vertical deletion waves

Delete each behavior across implementation, tests, docs, prompts/assets, Mix
tasks, config, CI, package files, and dependencies.

Suggested waves:

1. SubAgent modes, prompts, templates, and tests.
2. Public Session/Context/Turn/Evidence and Step duality after callers migrate.
3. Roles, PreludeStore, live editing, and related soaks/docs.
4. MCP server and root upstream transport/catalog/credential machinery.
5. `demo/`, `examples/`, old Livebooks, generated reports, and linked docs.
6. Evaluator datasets, oracles, paired comparisons, feedback A/B machinery,
   preregistration/report publishing after transcript constraints are resolved.
7. Redundant trace representations, metrics, Kino widgets, and unused analysis.
8. Unused dependencies, Mix aliases, workflows, scripts, ExDoc/package config.

Do not perform a giant unverified deletion. Do not keep compilation green with
compatibility shims. Migrate or delete each real caller.

### 12. Consolidate tests and benchmarks

- Collapse retained language cases into table-driven conformance suites where
  practical.
- Replace helper-level Kernel tests with deterministic contract integrations.
- Keep one realistic path per capability/prelude/TraceLog boundary.
- Keep thin CLI/viewer end-to-end tests.
- Keep a very small optional domain-blind live provider suite.
- Retain soaks only for atom, process/monitor, retained-state, or repeated
  compilation risks.
- Establish a meaningful area-level coverage baseline, then a modest enforced
  floor.
- Reduce `bench.check` to controlled parse/eval/sandbox/state/bundle/event/query
  costs.
- Move model comparisons to an optional thin harness over `Kernel.run/2`.

## Testing shape

Primary layers:

1. PTC-Lisp language, safety, and Babashka conformance.
2. Kernel contract integration with deterministic scripted capabilities.
3. Extension integration for files, TraceLog, bundles, and optional LLM adapter.
4. CLI and viewer black-box paths.
5. Optional live-model protocol drift checks.
6. Targeted lifecycle soaks.

Delete tests that mirror private helpers, assert obsolete intermediate maps,
mock every real Lisp path, duplicate conformance cases, freeze replaceable
prompt/presentation text, or enforce deleted compatibility behavior.

No `Process.sleep`; use monitors and deterministic synchronization.

## Quality gates

```text
mix precommit
  format, compile, Credo, schema/spec, deterministic conformance,
  retained integration/CLI tests, ptc_viewer tests

mix prepush
  Dialyzer, unused dependencies, slower deterministic checks

mix test --include e2e
  explicit optional live-provider verification
```

Do not run deleted demo/sibling projects, historical harnesses, or network tests
from `mix precommit`.

## Transcript constraint

Do not delete or substantially rewrite the current evaluator until the approved
private transcript work is integrated, re-homed to an optional experiment
harness, or explicitly superseded.

Retain canonical turn/capability/model-provider facts, safe effective config,
and prelude snapshots needed by the viewer. Private capture remains explicit,
gitignored, permission restricted, credential-free, and fail closed.

Experiment case/oracle/report concepts do not enter Kernel.

## Duplication and orphan audits

Run after each deletion wave:

- repository-wide `rg` for deleted modules, options, tasks, assets, config keys,
  environment variables, and links;
- `mix xref graph` and compile-cycle checks;
- `mix deps.unlock --check-unused`;
- `mix ptc.dna` while consolidation is active;
- coverage reports for retained but unreachable modules;
- package/ExDoc file inventories;
- CI, aliases, application config, Dialyzer apps, releases, and workflow search;
- final search across tests, docs, Livebooks, scripts, examples, and siblings.

Likely competing owners:

- SubAgent loop versus Lisp `agent.core`;
- Session versus Kernel state versus Lisp memory/history;
- SubAgent/Kernel native action normalization versus `agent.native`;
- public/native Step versus Kernel outcomes;
- Tracer/TraceLog/evaluator/private-transcript event representations;
- prompt inventory versus mission symbol/prelude inventory;
- role/store selection versus explicit frozen bundles;
- upstream discovery versus environment-local capabilities.

Choose one owner and delete the others rather than extracting premature shared
abstractions.

## Completion criteria

- A workflow and agent protocol can be authored entirely in PTC-Lisp/config.
- Kernel does not know about LLMs, turns, prompts, native model tools, or agent
  completion.
- Structural mission confinement is proven.
- Capability dispatch, limits, state, outcomes, and events satisfy the contract.
- `ptc.run`, the simplified REPL, TraceLog introspection, and viewer share the
  same config/runtime/event boundaries.
- SubAgent, roles/store, MCP/upstream, demo/examples, and obsolete harnesses are
  deleted.
- Retained behavior is covered primarily by conformance/integration/E2E tests.
- `mix precommit` and `mix prepush` pass.
