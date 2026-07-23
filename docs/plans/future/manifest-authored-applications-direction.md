# Manifest-authored applications — direction

> **Status:** direction / discussion material. This document describes the
> platform changes needed before applications such as a repository Code Scout
> can be authored with configuration, manifests, PTC-Lisp, and data only. It is
> not a single implementation plan, and every API shown below is proposed.

## 0. What this document is

**Goal.** Keep `mix ptc.run` as the generic top-level runner while making the
following authoring test pass:

> After PtcRunner has installed a bounded family of generic provider types, an
> application author can add a new task by writing host configuration, a
> manifest, PTC-Lisp components, and evaluation data. They do not add an
> Elixir module, edit `ProviderRegistry`, or create a task-specific Mix task.

A Code Scout is the proving application because it needs several capabilities
at once: repository discovery and bounded reads, canonical trace analysis, an
LLM-backed agent loop, structured candidate output, and eventually evaluation
of proposed prelude changes. The Kernel must not acquire a `scout` concept.

This direction is downstream of
[`capability-platform-direction.md`](capability-platform-direction.md). That
document defines the capability/provider grammar and the planned host-owned
JSON installation channel. This document asks what additional generic
resources and runner behavior are needed to use that platform for substantial
applications without Elixir changes.

**In scope:**

- the generic `mix ptc.run` authoring path;
- host-owned, data-driven provider installation;
- immutable repository and trace resources;
- local PTC-Lisp application components;
- structured candidate and evaluation artifacts;
- the boundary between proposing, evaluating, and promoting a change; and
- a read-only Code Scout as the first end-to-end acceptance case.

**Out of scope:**

- a `mix ptc.scout` command or any other task-specific frontend;
- teaching the Kernel what a repository, bug, pull request, or improvement is;
- arbitrary Elixir modules, shell commands, endpoints, or credentials in a
  manifest;
- allowing a running bundle to replace itself;
- automatic promotion of generated code into a shipped prelude;
- designing the agent's detailed planning or reflection strategy; and
- promising that every future capability kind can be invented without Elixir.
  The runtime still implements and audits generic provider types once; the
  no-Elixir promise applies to application instances assembled from them.

---

## Part I — Verified current state

The starting point is already close to the desired shape.

| Surface | Current behavior | Consequence |
|---------|------------------|-------------|
| `mix ptc.run` | Loads one strict manifest through `RunBuilder` and the default `ProviderRegistry` | The generic execution path already exists and should remain authoritative |
| Local components | A manifest can load path-confined PTC-Lisp files and declare dependencies | Application-specific behavior already requires no Elixir |
| Shipped libraries | A manifest can select fixed libraries such as `agent.core` and `log.core` | Generic agent behavior can be reused, but installing a new shared library still changes `Library` |
| Provider registry | The default registry installs only `llm` and `file-read`; additional builders are Elixir functions | New provider instances or MCP sources cannot currently be installed from the CLI without Elixir |
| `file-read` | Freezes one bounded directory and reads a whole UTF-8 file by an already-known relative path | It is safe and deterministic, but insufficient for repository discovery and context-efficient reads |
| MCP HTTP | `MCPSource.builder/1` can produce ordinary capabilities when trusted Elixir installs a fixed source | The protocol path exists, but its installation channel is not yet data-driven |
| Trace analysis | `TraceSnapshot` and `TraceCapability` expose four bounded queries; `log-analysis-v1` assembles them in a fixed REPL profile | The query engine exists, but a normal manifest cannot select a trace snapshot provider |
| Output | `ptc.run` prints the public result and can separately persist canonical trace and private inspection artifacts | A candidate can be returned, but there is no explicit atomic public-result artifact option |
| Bundles | Workflow and mission bundles are compiled and frozen before execution | A run can propose a new prelude, but must not mutate or replace its active bundle |

The missing feature is not a task framework. It is a data-driven way to
install bounded resource providers and select them from an ordinary manifest.

---

## Part II — Design principles

### A1. One generic runner

`mix ptc.run` remains the only non-interactive application runner. Application
names belong in files, labels, and component namespaces, not Mix task names.

Planned generic invocation:

```console
mix ptc.run ptc-code-scout.json \
  --host-config ptc-code-scout.host.json \
  --mission code-scout/input.json \
  --output tmp/code-scout-result.json \
  --trace tmp/code-scout-trace.jsonl
```

`--host-config` and `--output` are generic runner concerns. Neither option
knows that the application is a scout.

### A2. Preserve the authority ladder

The four roles from the capability-platform direction remain distinct:

| Layer | Owns | Code Scout example |
|-------|------|--------------------|
| Host config | Authority and installed ceilings | Repository root, trace directory, MCP command/endpoint, credentials |
| Manifest | Selection and narrowing | Which installed repository/trace tools enter the mission and their lower quotas |
| PTC-Lisp components | Application behavior | Search strategy, evidence collection, candidate format, retry policy |
| Generated program | One bounded action sequence | Calls `repo.search`, `repo.read`, and trace queries |

The manifest must not contain a repository path outside its own confined local
files, an MCP command, a remote endpoint, or a credential. The host-config
document is explicit trusted input supplied by the operator to `ptc.run`; it
is not referenced transitively by model-authored input.

Inside the manifest, provider destinations preserve a second split: **the
model that plans (workflow) is never the environment that touches data
(mission)**. That one sentence carries most of the architecture; guides and
tutorials should lead with it.

### A3. Capabilities expose resources; Lisp defines tasks

The runtime may know how to freeze and query a repository snapshot. It must not
know how to diagnose a failing test, decide that a prelude should change, or
write a review summary. Those policies are PTC-Lisp.

The same repository primitives must support unrelated applications such as a
documentation auditor, migration assistant, dependency investigator, or
security review. The same trace primitives must support operational analysis
without a repository.

### A4. Freeze read authority before execution

Repository and trace inputs are captured before workflow execution or model
calls. Capability callbacks query only the captured representation. Files that
change after capture cannot alter the run, and a path cannot escape the
host-granted root through traversal, symlinks, replacement, or aliases.

The snapshot is one authoritative representation for list, search, and read.
Those operations must not independently revisit the live filesystem and
observe different versions.

### A5. Search and ranged reads are primitives

Whole-file reads are not enough for serious code exploration. Requiring the
model to know every path in advance or load complete files wastes model
context and capability-result budget.

The smallest useful repository surface is:

- list bounded paths beneath a prefix;
- search bounded text with path and line evidence; and
- read a bounded line range from one file.

Traversal policy, decoding, indexing, result ordering, truncation, and bounds
belong to the provider. Higher-level exploration belongs to Lisp.

### A6. No ambient shell as a shortcut

No-Elixir authoring must not be achieved by adding a universal shell
capability to the default registry. Commands are authority and remain
host-installed. If an application needs GitHub, builds, test execution, or
patch application, it may use a specifically mapped MCP stdio/HTTP source or a
future audited provider whose command and allowed operations are frozen in
host config.

The manifest selects named operations; it does not supply a command string.

### A7. Improvement is proposal plus evaluation, not mutation

A running program cannot modify its active immutable bundle. A scout emits a
candidate as data. A later run evaluates that candidate against motivating and
held-out cases. Promotion is a separate host or human decision.

```text
immutable traces + repository snapshot
                 |
                 v
          analysis run
                 |
          candidate artifact
                 |
                 v
          evaluation run
                 |
          evidence report
                 |
                 v
       explicit promotion decision
```

This is controlled iterative improvement. It does not create a second mutable
code owner inside the Kernel.

### A8. Logs and source are untrusted data

Repository text, issue text, CI output, tool output, and trace payloads never
gain instruction authority. The application prompt and prelude must keep data
and instructions structurally separate. A log line that asks the model to
change policy is evidence to analyze, not a command to follow.

System prompts and shipped agent configuration remain domain-blind. Fixture
names, benchmark answers, and expected failure patterns belong only in test
data and tool-owned descriptions.

---

## Part III — The authoring package

A complete application should be ordinary data and PTC-Lisp. For an
application that intentionally reads the containing repository, its manifest
and host config can live at the repository root while its behavior and fixtures
remain grouped in a directory:

```text
ptc-code-scout.host.json     # trusted provider installation
ptc-code-scout.json          # capability selection, components, limits
code-scout/
  workflow.lisp             # orchestration and terminal result
  scout.lisp                # repository/trace analysis behavior
  input.json                # one mission request
  evaluation/
    motivating.json
    held-out.json
```

None of these files registers Elixir callbacks. `host.json` may instantiate
only provider source kinds compiled into the installed PtcRunner release.

### III.1 Planned host configuration

The host-config work should implement Track D of the capability-platform
direction rather than create a scout-specific loader. One explicit file is
loaded before the manifest, resolves credentials and provider resources, and
builds a `ProviderRegistry`.

Illustrative configuration:

```json
{
  "credentials": {},
  "install": {
    "workspace": {
      "source": "repository_snapshot",
      "root": ".",
      "include": ["lib/**", "test/**", "docs/**", "priv/**"],
      "exclude": ["docs/plans/**"],
      "ceilings": {
        "max_entries": 12000,
        "max_source_bytes": 32000000,
        "max_result_bytes": 250000
      }
    },
    "history": {
      "source": "ptc_trace_snapshot",
      "directory": "tmp/traces",
      "ceilings": {
        "max_source_bytes": 8000000,
        "max_result_bytes": 250000
      }
    }
  }
}
```

The top-level key is `install`, per the capability-platform grammar: the host
*installs*, the manifest *selects*. Both sources above are fixed-shape, so
their operations surface under default dotted public names —
`workspace.list`, `workspace.search`, `workspace.read`, `history.list-runs`,
`history.get-run`, `history.list-turns`, `history.counters`. An explicit
`tools` map with `as` renames remains available, and stays mandatory for
discovery sources such as MCP, where the map is the security allowlist.

The exact schema is a decision for the capability-platform plan. The important
contract here is that local resource paths and inclusion policy are host-owned,
resolved relative to the canonical host-config directory, and absent from the
manifest and public provider snapshot.

### III.2 Planned manifest selection

The application manifest uses the same narrowing grammar as remote providers:

```json
{
  "version": 1,
  "workflow": {
    "components": [
      {"library": "agent.core"},
      {"id": "code-scout.workflow", "path": "code-scout/workflow.lisp", "dependencies": ["agent.core"]}
    ],
    "entry": "code-scout.workflow/run"
  },
  "mission": {
    "components": [
      {"id": "code-scout", "path": "code-scout/scout.lisp"}
    ],
    "data": {}
  },
  "providers": {
    "workflow": [
      {"name": "llm", "config": {"model": "deepseek", "cache": false}}
    ],
    "mission": [
      {"name": "workspace"},
      {"name": "history"}
    ]
  },
  "input": {"path": "code-scout/input.json"}
}
```

Selecting a provider without `config` exposes every name the host installed
for it — safe, because selection can only narrow. `allow`, `model_visible`,
and ceiling keys appear only when the application wants less than it was
granted.

This example reflects the current built-in `llm` selection. The capability
platform direction must decide whether LLM model installation also moves into
host config; that decision should apply to every application, not be made for
Code Scout alone.

Local components are sufficient for application behavior. A separate
data-driven shared-library catalog is useful for distribution, but is not a
prerequisite for no-Elixir application authoring. For the common case where
the workflow only forwards the input task to the installed agent loop, a
shipped generic `agent.main` library removes even that file: the manifest
selects `{"library": "agent.main"}`, sets `"entry": "agent.main/run"`, and
ships no workflow component. `agent.main` is ordinary installed PTC-Lisp — no
new grammar — and stays domain-blind: task text and loop configuration come
from the input object.

### III.3 Candidate result contract

The initial scout is read-only. It returns a bounded JSON-like proposal:

```json
{
  "decision": "propose-change",
  "target": "priv/preludes/kernel/agent.core.lisp",
  "evidence": [
    {"run_id": "...", "event_sequences": [12, 18]},
    {"path": "priv/preludes/kernel/agent.core.lisp", "lines": [70, 96]}
  ],
  "generalized_failure": "...",
  "candidate": {
    "format": "unified-diff",
    "content": "..."
  },
  "evaluation_plan": {
    "motivating_cases": ["..."],
    "held_out_cases": ["..."],
    "regression_metrics": ["success", "tool_calls", "tokens"]
  },
  "risks": ["..."]
}
```

The result must distinguish a generalized behavior gap from a one-off product
bug or bad input. `no-change` and `insufficient-evidence` are first-class
decisions; continual code production is not success.

An optional generic `--output PATH` should atomically persist exactly the
public terminal result with no clobber. Until that exists, stdout remains a
valid but less ergonomic channel. Trace and inspection artifacts retain
their existing separate trust policies.

---

## Part IV — Generic provider contracts

### IV.1 Repository snapshot provider

One host-installed repository snapshot emits three ordinary capabilities.
Operations surface publicly as `<provider>.<operation>` by default (e.g.
`workspace.search`); `as` renames stay available and are not reserved Kernel
names.

| Operation | Required behavior |
|-----------|-------------------|
| `list` | Sorted, paginated relative paths beneath an optional prefix |
| `search` | Literal text search with sorted path/line matches, bounded context, pagination, and explicit truncation |
| `read` | One UTF-8 file line range with stable line numbers, byte counts, and explicit EOF/truncation |

The first implementation should prefer literal search. User-authored regular
expressions can introduce scheduler-level `:re` risk and are not necessary for
the acceptance application. Regex search requires a separately proven bounded
engine or the same hard guard adopted by the schema work.

Snapshot invariants:

- paths are normalized relative paths and never reveal the host root;
- traversal, absolute paths, NULs, devices, and symlinks are rejected;
- include/exclude policy is frozen by the host, not supplied per call;
- all operations query the same captured bytes and path inventory;
- files are bounded individually and in aggregate;
- invalid UTF-8 and oversized files have stable closed classifications;
- result ordering and cursors are deterministic;
- provider metadata contains only safe policy summaries and content hashes;
- callback closures or owners retain the authority-bearing root privately; and
- cleanup releases indexes or snapshot owners exactly once.

Whether the provider uses Git's tracked-file inventory is a host policy. A
plain directory capture must remain possible for non-Git inputs. If Git-aware
capture exists, it must not launch a manifest-selected command or silently
change the meaning of the same configured source.

### IV.2 PTC trace snapshot provider

The source kind is named `ptc_trace_snapshot`, not `trace_snapshot`: it reads
exactly one format — the canonical trace JSONL that `ptc.run --trace` writes —
the way `openapi` names a spec format rather than "any API". It is not a
generic log/trace ingester; OTel spans, application logs, or foreign trace
formats would be a different source kind (or arrive via MCP), not a widening
of this one.

The existing `TraceSnapshot`, `TraceCapability`, and canonical `TraceLog`
query layer remain authoritative. The new work is a host-config provider
builder that exposes that same implementation to ordinary manifests.

Do not implement a second JSONL parser or parallel query algebra. The fixed
`log-analysis-v1` profile may continue to use the same builder/assembly
internally; profile mode and manifest mode should differ only in who selects
the already-frozen provider.

Trace paths, snapshot handles, private payloads, and source bytes remain absent
from public metadata. Normal trace snapshots expose sanitized canonical data
only. Private inspection artifacts are not accepted as normal trace resources.

### IV.3 Richer local tools through MCP

Repository list/search/read and canonical trace queries justify native generic
providers because PtcRunner already owns their safety and data contracts.
Higher-risk operations should initially come from explicitly installed MCP
sources:

- Git status and diff operations;
- GitHub issue, pull request, and CI-log retrieval;
- running named test or formatting commands;
- applying a candidate patch to a disposable worktree; and
- publishing an evaluation artifact.

The host config freezes the MCP command or endpoint and maps a finite set of
public tools. The manifest can only narrow that set. This exercises the common
capability platform instead of growing a Code Scout subsystem.

### IV.4 Write effects remain a separate gate

The proving Code Scout is read-only and proposes a patch as its terminal
result. Applying a patch, changing a prelude file, starting a process, or
publishing externally is a write effect and depends on the capability-platform
decision for write-capable providers.

If later enabled, the first write target should be a disposable candidate
workspace, never the active source tree or shipped bundle. The provider must
freeze the target, allowed operations, and ceilings; record capability
activity; expose deterministic post-operation evidence; and make retries after
partial effects explicit rather than automatic.

---

## Part V — Improvement and evaluation workflow

### V.1 Analysis run

The scout receives a bounded objective and queries immutable evidence. It may:

1. list and classify relevant runs;
2. inspect bounded turns and counters;
3. search the repository for the owning contract;
4. read only the necessary source ranges;
5. distinguish application defects from reusable agent-behavior gaps; and
6. return one structured decision.

It must cite evidence that a deterministic evaluator can verify exists in the
granted snapshots. Unsupported assertions are a failed result even if the
proposed patch appears plausible.

### V.2 Candidate materialization

The candidate is inert data when the analysis run ends. A trusted host step
may materialize it into a new file or disposable worktree. Materialization is
not hidden inside trace persistence or result formatting.

The active bundle, repository snapshot, and trace snapshot remain unchanged.
This preserves reproducibility and prevents a run from changing the evidence
against which it is reasoning.

### V.3 Evaluation run

A separate generic manifest evaluates the candidate. Its inputs include:

- the candidate artifact and its source hash;
- motivating cases that should improve;
- previously successful regression cases;
- held-out cases not cited by the scout; and
- metric ceilings such as tool calls, model calls, duration, and tokens.

The evaluator returns evidence, not a promotion side effect. At minimum it
classifies:

- candidate compiles or is rejected;
- motivating behavior improves, regresses, or is unchanged;
- held-out behavior improves, regresses, or is unchanged;
- resource use stays within policy or regresses; and
- the candidate is recommended, rejected, or inconclusive.

Exact prelude-component compilation may require a generic candidate-bundle
evaluation facility. Do not approximate that contract with `kernel/eval-source`
if doing so would bypass component dependencies, exports, capability
requirements, or bundle validation. This is a decision gate to investigate
before claiming automated prelude evaluation.

Recommended shape: a runner-level `--component-override ID=PATH` option on
`ptc.run`. It is trusted CLI input (host rung), substitutes exactly one
component's source before bundle compilation, and runs the result under full
bundle validation — dependencies, exports, capability requirements,
signatures. Materializing `candidate.content` into that file is the explicit
trusted step of V.2, visible in the invoking shell rather than hidden in the
runtime. No new capability kind is introduced, and the running bundle still
cannot modify itself.

### V.4 Promotion

Promotion is outside the initial application contract. A human or trusted host
workflow reviews the candidate and evaluation artifact, applies the change,
and runs repository quality gates. A future promotion capability must be
explicitly installed as write authority and must never be implied merely by
possessing repository read access.

---

## Part VI — Vertically complete roadmap

Each slice must land with focused contract tests, durable documentation for
implemented behavior, and no parallel authoritative path.

### Slice A — Generic host-config installation

- Complete Track D from the capability-platform direction.
- Add a generic `ptc.run --host-config PATH` option.
- Strictly parse one bounded, duplicate-key-rejecting host document.
- Resolve its paths relative to its canonical directory.
- Build one registry from built-ins plus configured provider instances.
- Reject duplicate provider names and attempts to replace built-ins.
- Close all resources on load, build, run, persistence, and cancellation
  failures.
- Prove that omitting `--host-config` preserves current `ptc.run` behavior.

**Gate:** a configured MCP provider can be selected and narrowed by an
ordinary manifest with no Elixir registration change.

### Slice B — Repository snapshot capabilities

- Define the list/search/read schemas, pagination, truncation, and stable
  errors first.
- Implement one immutable captured representation shared by all operations.
- Add the provider type to host config and ordinary capability snapshots.
- Add adversarial path, replacement, symlink, UTF-8, size, cursor, and
  deterministic-order tests.
- Document the implemented provider contract outside `docs/plans/`.

**Gate:** a manifest-authored agent can discover an unknown file, locate a
literal, and read its surrounding range without whole-repository or live-file
access.

### Slice C — Manifest-selectable trace snapshots

- Adapt the existing trace snapshot owner into a provider builder.
- Reuse the existing four trace capabilities and query implementation.
- Install trace directories only through host config.
- Align resource ownership and cleanup between profile-backed and
  manifest-backed entry paths.
- Prove equivalent queries return equivalent public results in both paths.

**Gate:** one ordinary manifest can query both repository and canonical trace
snapshots without a special profile or Elixir assembly.

### Slice D — Public result artifacts

- Define `--output PATH` as an optional generic `ptc.run` destination.
- Persist only the bounded public terminal result.
- Use atomic no-clobber publication and stable errors.
- Keep public result, canonical trace, and private inspection artifacts
  separate.
- Test success and every failure after meaningful capability activity.
- Land this slice early: nothing in it depends on Slices B or C, and every
  multi-run story (evaluation, cron, CI) is otherwise scraping stdout.

**Gate:** a candidate proposal can be passed to a later run without scraping
human console output.

### Slice E — Read-only Code Scout acceptance application

- Add only host JSON, manifest JSON, local PTC-Lisp, and fixture data.
- Use `agent.core`; do not add a scout-specific Kernel or Mix module.
- Analyze representative failed traces and repository sources.
- Return `no-change`, `insufficient-evidence`, or a structured proposal with
  verifiable citations.
- Include prompt-injection text in logs/source and prove it remains data.
- Keep prompts domain-blind and evaluation cases outside shipped prompts.

**Gate:** deleting the application files removes the entire Code Scout; no
runtime file contains its domain vocabulary.

### Slice F — Candidate evaluation

- Decide and implement the minimum generic facility for evaluating a candidate
  component under the same bundle contracts as production (recommended:
  `--component-override`, V.3).
- Separate motivating, regression, and held-out corpora.
- Compare outcomes and resource usage under fixed limits.
- Emit a structured evaluation artifact with hashes binding candidate,
  fixtures, provider snapshots, and effective bundles.
- Keep promotion external.

**Gate:** an improvement claim is reproducible from frozen inputs and cannot
pass solely by fixing its cited training cases while regressing held-out cases.

### Slice G — Optional guarded writes

- Resolve the platform-wide write-capability policy first.
- Prefer a mapped MCP tool or narrowly audited candidate-workspace provider.
- Never grant writes merely because a read provider is selected.
- Define partial-effect, retry, cancellation, and cleanup semantics.
- Require explicit host installation and manifest selection.

**Gate:** a candidate may be materialized in a disposable workspace without
granting authority over the active source tree or allowing arbitrary commands.

---

## Part VII — Acceptance matrix

| Case | Expected result |
|------|-----------------|
| No host config | Current `ptc.run` behavior remains unchanged |
| Unknown configured source | Fails before provider activity or model calls |
| Manifest selects an uninstalled provider | `:unknown_provider`-class failure |
| Manifest tries to widen `allow`, roots, timeout, or result ceiling | Fails during assembly |
| Repository changes after capture | The run continues to observe the frozen snapshot |
| Repository path traverses or crosses a symlink | Closed denied/invalid request; no escaped data |
| Search exceeds match/result bounds | Deterministic truncated page or closed limit error, as specified |
| Trace source is malformed or changes during capture | Existing stable trace-source failure |
| Model follows an instruction embedded in a log | Evaluation failure; embedded text has no authority |
| Scout finds only a one-off defect | Structured `no-change`, not a forced prelude patch |
| Candidate fails component compilation | Evaluation rejects before running cases |
| Candidate improves cited cases but regresses held-out cases | Evaluation rejects or marks inconclusive |
| Run fails after resource creation | Every provider resource closes exactly once |
| Public result/trace/error is inspected | Host paths, credentials, private payloads, and snapshot handles are absent |

---

## Part VIII — Open questions

1. **Host-config CLI contract.** Is one explicit `--host-config` file enough
   for v1? Recommendation: yes. Avoid implicit discovery, includes, merging,
   and precedence rules until a demonstrated application requires them.
2. **Provider grammar for local snapshots.** Resolved: one `source`
   discriminator field covers both families under the same outer provider and
   manifest-narrowing grammar. Connector sources (`mcp_*`, `http_get`,
   `openapi`) are *reached* and implement the `Transport` exchange seam;
   snapshot sources (`repository_snapshot`, `ptc_trace_snapshot`) are *captured*
   at build and implement the Capability contract directly — local queries are
   never forced through a remote-shaped abstraction.
3. **Repository inventory.** Plain directory snapshot, Git-tracked snapshot,
   or an explicit host choice? Recommendation: make the mode host-owned and
   explicit; never silently depend on repository state.
4. **Search language.** Literal-only initially, glob plus literal, or safe
   regex? Recommendation: glob path filters plus literal text in v1. Regex is
   not required for the proving application and carries node-level risk.
5. **Result artifact.** Is stdout sufficient, or should `--output` be part of
   the generic runner? Recommendation: add atomic public-result output before
   building a multi-run evaluation workflow.
6. **LLM installation.** Should model selection remain in the manifest or move
   behind the same host-installed provider grammar? This belongs to the
   capability-platform direction and must remain consistent across all tasks.
7. **Candidate representation.** Unified diff, complete component source, or a
   closed tagged union? Recommendation: require complete source for exact
   component evaluation; a diff may accompany it for review but must not be
   the sole authoritative candidate.
8. **Reusable application distribution.** Are manifest-relative local
   components sufficient, or is a data-driven installed component catalog
   needed? Recommendation: defer the catalog until copying local components is
   a demonstrated problem; it is not required for the first no-Elixir task.
9. **Evaluation orchestration.** Should a human/shell invoke analysis and
   evaluation runs separately, or should a future generic pipeline manifest
   compose runs? Recommendation: prove the two explicit runs first. Do not add
   a workflow engine before the artifact and evaluation contracts stabilize.
10. **Write authority.** Which destination may receive write capabilities, and
    how are partial effects retried or surfaced? This remains blocked on the
    platform-wide write decision; the read-only scout does not need it.

---

## Appendix A — The no-Elixir consistency checklist

An application qualifies as manifest-authored when all answers below are yes:

1. Does it run through `mix ptc.run`, not a domain-specific Mix task?
2. Are endpoints, commands, credentials, local roots, and installed ceilings
   declared only by the trusted host channel?
3. Does the manifest only select installed names and narrow authority?
4. Is application behavior entirely local or installed PTC-Lisp?
5. Are all effects ordinary capabilities with schemas, effects, bounds,
   accounting, traces, and deterministic safe snapshots?
6. Can the application be removed without deleting domain-specific Elixir?
7. Can its fixtures and prompts change without recompiling PtcRunner?
8. Are generated changes inert candidates until a separate evaluation and
   promotion decision?

If a proposed application fails because it needs a new generally useful
primitive, add and audit that provider type as platform work. If it fails
because it needs task policy in Elixir, move that policy into PTC-Lisp.

## Appendix B — Code Scout completion test

The direction is proven when a clean installed PtcRunner can execute a Code
Scout supplied as application files and satisfy all of the following:

- the command is ordinary `mix ptc.run`;
- no `.ex` or Mix task file is added or modified for the application;
- the host grants one repository snapshot and one canonical trace snapshot;
- the manifest narrows those grants and selects generic agent behavior;
- local PTC-Lisp discovers relevant files and traces without prelisted answers;
- the result cites bounded evidence and may decline to propose a change;
- a proposed prelude is emitted as an inert, content-addressed candidate;
- a separate generic run evaluates the exact candidate bundle against
  motivating, regression, and held-out cases; and
- applying or promoting the candidate remains an explicit write-authority
  decision outside the analysis run.
