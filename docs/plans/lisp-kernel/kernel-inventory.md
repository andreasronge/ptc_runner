# Minimal Programmable Kernel — Temporary Migration Inventory

**Status:** active migration inventory. The core owner primitives introduced in
`exp/minimal-kernel` Slice 1 are tracked below; all rows remain open until their
listed destination and final deletion audit are complete. Delete this document
after migration closes.

**Contract:** [`kernel-contract.md`](kernel-contract.md)

**TraceLog contract:** [`tracelog-contract.md`](tracelog-contract.md)

**Sequence:** [`kernel-migration.md`](kernel-migration.md)

## Classification

- **foundation** — retain initially; simplify only after the new path works.
- **new path** — implement the normative Kernel contract here.
- **migrate** — extract named retained behavior to the stated destination.
- **delete** — belongs only to the old product.
- **experiment** — temporarily retained with an explicit exit condition.

Every `migrate` item must name its destination. Every `experiment` item must
name its re-home/delete condition. `unknown` is not a durable classification.

## Source inventory

### PTC-Lisp and sandbox

| Area | Class | Retained behavior / destination |
| --- | --- | --- |
| `lib/ptc_runner/lisp.ex` | migrate | Extract a neutral internal evaluation entry for Kernel; replace agent/context/journal/public-Step options at cutover. |
| `lib/ptc_runner/lisp/parser*`, `fast_parser*`, AST/source modules | foundation | Parsing and source representation. Add span preservation as an early language workstream. |
| `lib/ptc_runner/lisp/analyze*` | migrate | Retain static safety and Clojure semantics; remove agent budget/history/upstream surfaces and add environment/profile inputs. |
| Parser/analyzer `program` support | new path | Capture bounded forms without workflow evaluation/resolution; preserve origin/spans; no general collection quote/macros. |
| `lib/ptc_runner/lisp/eval*`, `runtime*`, `env*` | migrate | Retain closures/functions/interop/definitions behind a neutral evaluation context; remove agent, upstream, journal, and public-Step coupling. |
| `Lisp.Eval.ParallelRunner`, `ParallelBudget`, `pmap`/`pcalls` workers | migrate | Retain bounded parallel data/capability execution; integrate provider-task limits and reject concurrent `kernel-eval` with recoverable `:busy`. |
| `lib/ptc_runner/lisp/retained_size.ex` | foundation | Evaluation-memory and capability-result size enforcement. |
| `lib/ptc_runner/lisp/format*`, `formatter*`, keyword representation | foundation | Deterministic Lisp formatting and keyword boundary. |
| `lib/ptc_runner/lisp/registry*`, language/spec validation | foundation | Language reference and conformance. Remove agent-specific registrations only. |
| `lib/ptc_runner/lisp/discovery.ex` | migrate | Replace upstream/catalog semantics with environment-local capability metadata. |
| SubAgent budget/plan/journal special surfaces in Lisp | delete | Replace with generic runtime usage, workflow annotations, or optional capabilities. |
| `*1`, `*2`, `*3` support | migrate | Retain only for direct REPL history; agent history becomes ordinary workflow data. |
| `return` / `fail` | foundation | Workflow-neutral terminal control signals. |
| `lib/ptc_runner/sandbox.ex` | migrate | Extract process isolation, timeout, heap, and cleanup behind a neutral interface; remove Context/TraceContext/MCP-specific API coupling. |

### Prelude foundation and deployment platform

| Area | Class | Retained behavior / destination |
| --- | --- | --- |
| `lib/ptc_runner/lisp/prelude/compiler.ex` and compiler helpers | migrate | Retain protected namespaces, exports, `requires`, and compilation after removing SubAgent signature and upstream-specific inference. |
| `lib/ptc_runner/lisp/prelude/bundle.ex` | migrate | Become explicit bounded component-ID DAG `compile_bundle/1` with frozen provenance. |
| Protected namespace/export/prompt inventory primitives | foundation | Split workflow/mission validation and mission-only model inventory. |
| `priv/preludes/agent/*.lisp` | migrate | Split/rewrite as `agent.native`, `agent.core`, `agent.feedback`, `agent.retry`, `workflow.event`, and `result`. |
| `PtcRunner.PreludeRolePolicy` and grants | delete | Roles remain an optional future environment-builder adapter. |
| `PtcRunner.PreludeRuntime` | delete | Kernel accepts frozen bundles/environments. |
| `PtcRunner.PreludeStore*` | delete | No mutable/versioned store in V1. |
| `PtcRunner.PreludeCandidate` | delete | No live active-bundle editing in V1. |
| Store/form-edit tools and churn soaks | delete | Candidate authoring/promotion is deferred and host-gated. |

### New Kernel path

| Area | Class | Retained behavior / destination |
| --- | --- | --- |
| `Kernel.Capability` responsibility | new path | Slice 1: host-owned metadata/callback representation; provider registry/manifest selection remains Slice 8. |
| `Kernel.WorkflowEnvironment` | new path | Slice 1: frozen workflow capability map; frozen bundle assembly validation follows Slice 2. |
| `Kernel.MissionEnvironment` | new path | Slice 1: structurally distinct map rejecting reserved workflow routes; mission bundle/context follows later slices. |
| `Kernel.Limits` | new path | Slice 1: normalized positive hard ceilings. |
| `Kernel.RunState` | new path | Slice 1: atomic deadline, counters, serialized evaluation-memory lease, and closed status; dropped-event accounting joins final run path. |
| `Kernel.Dispatcher` | new path | Slice 1: validation, atomic reservation, timeout, fault containment, bounds, and uniform envelope; Lisp boundary wiring follows Slice 3. |
| Host provider-registry interface | new path | Host-owned name-to-builder map; manifests can select names but never register executable code. |
| `Kernel.EventSink` responsibility | new path | Slice 1: canonical bounded memory sink with normal lossy/private fail-closed policies; final run-owned integration follows Slice 3. |
| `Kernel.Result` / `Kernel.Error` | new path | Only public Kernel outcomes. |
| `Kernel.compile_bundle/1` | new path | Slice 2 in progress: bounded component-ID DAG, deterministic ordering, frozen source hashes, prelude attachment, and explicit tool-requirement validation. Provider `requires` schema and artifact limits remain open. |
| Bundle compilation limits | new path | Component/edge/source/time/heap/artifact/diagnostic ceilings independent of the run deadline. |
| `Kernel.run/2` | new path | Slice 3 in progress: typed explicit configuration, bounded direct entry execution, canonical lifecycle events, and workflow capability dispatch. Workflow bundle assembly and mission confinement remain open. |
| Reserved `kernel-eval` | new path | Slice 4 in progress: workflow-to-mission source route, serialized leases, transactional memory, and mission-only capability dispatch. Static Program values and Lisp helpers remain open. |
| Opaque Program value | new path | Slice 5 in progress: static opaque source identity with byte size/digest, analyzer capture, and embedded kernel-eval route. Origin/spans and Lisp helper APIs remain open. |
| `kernel/eval` / `kernel/eval-source` prelude | new path | Explicit embedded versus dynamic paths over one discriminated `kernel-eval` capability. |
| Generic runtime usage/remaining | new path | Read-only changing enforced-resource snapshots. |
| Workflow annotation | new path | Bounded host-stamped semantic annotation, not canonical event authority. |

### Experimental Kernel implementation

| Area | Class | Retained behavior / exit condition |
| --- | --- | --- |
| `lib/ptc_runner/kernel.ex` | experiment | Evidence/source for mechanisms. Replace at public cutover; do not refactor into target wholesale. |
| `lib/ptc_runner/kernel/state_handle.ex` | migrate | Reuse atomic size-checked ownership in RunState; simplify leases after sequential confinement tests. |
| `lib/ptc_runner/kernel/inner_prelude.ex` | migrate | Environment-specific frozen-bundle/`requires` validation, then delete old module. |
| `lib/ptc_runner/kernel/action.ex` | delete | Port strict native action policy to `agent.native`; retain only generic provider normalization. |
| `lib/ptc_runner/kernel/eval.ex` and `kernel/eval/*` | experiment | Re-home/delete after private transcript work and thin experiment harness exist. |
| `lib/ptc_runner/kernel/feedback_ab.ex` | delete | Delete with A/B variants, task, tests, and reports. |
| `priv/kernel_feedback_variants/` | delete | Delete with feedback A/B harness. |

### SubAgent and surrounding platform

| Area | Class | Destination |
| --- | --- | --- |
| `lib/ptc_runner/sub_agent.ex` and `sub_agent/**` | delete | Retained policies move to shipped Lisp libraries or generic Kernel capabilities. |
| SubAgent definitions, validation, compiler, chaining, child agents | delete | No compatibility facade. |
| Text/JSON modes, code-fence/JSON recovery, combined transports | delete | LLM is one generic workflow capability; policies live in Lisp. |
| Prompt expansion, Mustache templates, prompt modes | delete | Workflow/prelude functions construct prompts. |
| Compaction, plan/progress, journaling, completion modes | delete | Optional Lisp policies/capabilities only when demonstrated. |
| Built-in grep and exposure/native-preview machinery | delete | Capabilities/preludes replace these. |
| LLM registry inheritance and SubAgent retries | delete | Provider registry builds workflow capability; retry policy lives in Lisp. |
| `priv/prompts/` | delete | Remove after last SubAgent consumer; retain Lisp agent preludes. |

### Public data abstractions

| Area | Class | Retained behavior / destination |
| --- | --- | --- |
| `PtcRunner.Step`, `Step.Native`, `Step.Public` | migrate | Keep an internal Lisp evaluation result; public execution becomes Kernel Result/Error. |
| `PtcRunner.Session` | migrate | Minimum direct REPL history/state primitive; delete old public semantics. |
| `PtcRunner.Context`, `PtcRunner.Turn` | delete | Explicit input and canonical events replace them. |
| `PtcRunner.Evidence*` | delete unless proven | Retain only if a current Kernel/TraceLog contract test demonstrates an independent need. |
| `PtcRunner.Schema` / generated `priv/ptc_schema.json` | migrate | Re-evaluate against manifest/capability schemas; delete SubAgent protocol schema. |
| `PtcRunner.PtcToolProtocol` | delete | Native action policy moves to Lisp; Kernel capability contract replaces it. |
| `PtcRunner.Tool` | migrate | Extract only callback normalization into Capability, then delete Tool and its SubAgent/exposure/cache/private-policy fields with the last old caller. |
| `PtcRunner.Template`, `Mustache`, `Temporal` | delete | Last consumers are removed agent modes. |
| `PtcRunner.Chunker` | delete unless proven | Retain only with independent language/Kernel consumer and integration test. |

### Remaining root modules and cross-cutting runtime

| Area | Class | Retained behavior / destination |
| --- | --- | --- |
| `PtcRunner.PreludeOrigin` | migrate | One bounded sanitized origin type for Component, diagnostics, and traces. |
| `PtcRunner.SymbolInventory` | migrate | Derive bounded model-visible inventory exclusively from MissionEnvironment. |
| `PtcRunner.TraceContext` | migrate/delete | Move unavoidable IDs/provenance to RunState and canonical events, then delete if no independent caller remains. |
| `PtcRunner.Dotenv` | migrate | CLI/provider-builder convenience only; never ambient Kernel authority. |
| `PtcRunner.PromptLoader`, `PtcRunner.Prompts` | delete | Remove with compiled SubAgent prompt files and last callers. |
| `PtcRunner.LLM` | migrate | Thin embedding/provider-registry facade for `llm/request`; no agent policy. |

### LLM integration

| Area | Class | Retained behavior / destination |
| --- | --- | --- |
| `PtcRunner.LLM.ReqLLMAdapter` | migrate | Optional provider implementing uniform `llm/request` workflow capability. |
| Provider transport normalization | migrate | Bounded provider-neutral data and safe metadata. |
| `PtcRunner.LLM.Registry` / default registry | migrate | Strict host provider registry; remove inheritance and arbitrary callbacks from manifests. |
| Structured output, text/tool mode switching, prompt caching wrappers | delete | Policy lives in Lisp or is deferred. |
| Streaming | delete/defer | V1 non-goal. |

### TraceLog and viewer

This area is governed by [`tracelog-contract.md`](tracelog-contract.md).

| Area | Class | Retained behavior / destination |
| --- | --- | --- |
| Canonical TraceLog event/envelope | foundation | One bounded schema shared by Kernel, capabilities, transcript harness, and viewer. |
| JSONL handler/collector | migrate | Bounded ordered normal sink with dropped-event accounting. |
| Private transcript sink | experiment | Explicit fail-closed sink in experiment harness; re-home before evaluator deletion. |
| `TraceLog.Introspection` | migrate | Simplified source-scoped run discovery, metadata, turns, counters, pagination, bounds. |
| `log/` prelude | new path | Swappable mission prelude over explicitly granted trace capabilities. |
| `TraceLog.Analyzer` | migrate | Keep only shared query/index behavior required by viewer/log capability. |
| Trace memory sink | migrate | Retain bounded sink if needed by REPL/tests/log capability. |
| `Tracer`, `Tracer.Timeline`, Chrome exports | delete unless viewer requires | Move required facts to canonical events, then delete competing representations. |
| `Metrics.Statistics`, `Metrics.TurnAnalysis` | delete/re-home | Optional experiment harness only if actively used. |
| `PtcRunner.Kino.TraceTree` | delete | Remove with old Livebooks/Kino dependency. |
| `ptc_viewer/` | foundation | Retain and align with canonical events/private transcripts. Interactive Lab deferred. |

### Upstream and MCP

| Area | Class | Destination |
| --- | --- | --- |
| `lib/ptc_runner/upstream/**` | delete | A standard capability provider is the extension seam; no anticipatory generic adapter. |
| `mcp_server/` | delete | Optional MCP frontend may return later over shared manifest/run builder. |
| MCP/OpenAPI transports, credentials, catalogs, discovery | delete | Remove modules, deps, tests, docs, config, releases, CI. |
| REPL upstream flags/catalog modes | delete | REPL uses explicit shared manifest/environment grants. |

## Mix tasks

| Task | Class | Destination |
| --- | --- | --- |
| `ptc.repl` | migrate | Small direct Lisp REPL with history, scripts, bundles/shared manifest, canonical trace. |
| `ptc.run` | new path | Thin shared manifest/run-builder frontend. |
| `ptc.viewer` | foundation | Read-only trace/transcript frontend in V1. |
| `ptc.validate_spec`, `ptc.update_spec_checksums`, `ptc.gen_docs` | foundation | Retain language/spec maintenance. |
| `ptc.conformance_report`, `ptc.clojure_audit`, `ptc.audit_upstream` | foundation | Retain; rename “upstream” to clarify reference-runtime meaning. |
| `ptc.smoke`, `ptc.install_babashka` | foundation | Retain while conformance uses Babashka. |
| `bench.check` | migrate | Small deterministic runtime regression corpus. |
| `parallel_workers` | delete | Delete with example. |
| `ptc.kernel_feedback_ab` | delete | Delete with A/B harness. |
| `ptc.kernel_eval` | experiment | Re-home to thin optional harness after transcript work. |
| `ptc.dna` | migrate | Keep through duplication audit; remove with `ex_dna` afterward if unused. |
| release/smoke tasks | migrate | Retain only checks for shipped language/Kernel/viewer artifacts. |

## Top-level directories and assets

| Path | Class | Exit/destination |
| --- | --- | --- |
| `lib/`, core `test/` | migrate | Follow per-area rows; remove obsolete support/fixtures vertically. |
| `config/`, `.env.example` | migrate | Retain only Kernel/provider/frontend defaults; remove SubAgent, MCP/upstream, demo, and obsolete release configuration. |
| `priv/` | migrate | Retain language/spec and rewritten Lisp libraries; delete prompts, variants, schemas, and other assets with their last consumers. |
| `docs/guides/` | delete/replace | Extract concise Kernel, capability/prelude, TraceLog, REPL/runner docs first. |
| `docs/conformance/`, specification, function reference, conformance gaps | foundation | Retain. |
| `docs/plans/lisp-kernel/private-experiment-transcripts.md` | experiment | Complete/re-home transcript work; retain viewer contract rationale. |
| `docs/plans/future/`, `docs/plans/archive/` | migrate | Keep only rationale for surviving systems; delete rejected-system plans. |
| `docs/guidelines/` | migrate | Keep active repository rules not already canonical in `AGENTS.md`. |
| `examples/` | delete | Convert unique retained mechanisms into focused integration fixtures first. |
| `demo/` | delete | Replace with optional thin Kernel scenario harness only if actively needed. |
| `livebooks/` | delete/replace | Remove current set; add at most one maintained Kernel playground later. |
| `blog/`, `images/` | delete/move | Move to website repository if needed. |
| `reports/kernel_eval/` | delete | Extract durable conclusions; generated/private artifacts remain untracked. |
| `bench/` | migrate | Small domain-blind deterministic corpus and baselines only. |
| `scripts/` | migrate | Keep active release/repository automation for retained product. |
| `.github/` | migrate | Remove demo/MCP/examples/old docs jobs; retain conformance/Kernel/viewer gates. |
| `.githooks/` | migrate | Keep only hooks for retained prepush/precommit/release checks. |
| root README/CHANGELOG/package metadata (`mix.exs`, `mix.lock`) | migrate | Describe and package only the retained language, Kernel, runner/REPL, and viewer integration. |
| `AGENTS.md`, `CLAUDE.md`, `usage-rules*`, licenses/REUSE files | foundation | Retain canonical repository/dependency instructions and licensing; update stale product references only. |
| formatter/Credo/Dialyzer/link-check/Docker control files | migrate | Remove deleted paths and dependencies; retain checks required by the final package/frontends. |
| `conformance_inventory.json` | foundation | Retain with language conformance tooling. |
| `priv/plts/`, `_build/`, `deps/`, `tmp/`, `erl_crash.dump` | local cleanup | Not architecture or tracked product content. |

## Dependencies

| Dependency | Class | Condition |
| --- | --- | --- |
| `jason`, parser/runtime dependencies | foundation | Retain. |
| `stream_data` | foundation | Retain for language/property tests. |
| `req`, `req_llm` | migrate | Retain only for optional standard LLM provider. |
| `telemetry` | migrate | Retain only if canonical event/host instrumentation uses it. |
| `ptc_viewer` path dependency | foundation | Retain dev/test integration. |
| `kino` | delete | Remove with Kino/Livebooks. |
| `ex_dna` | experiment | Keep through final duplication audit, then remove if no active task. |
| `recon` | delete unless proven | Retain only for an active lifecycle/soak check. |
| `benchee` | migrate | Retain only if deterministic benchmark task uses it. |
| MCP/upstream-only dependencies | delete | Remove with last transport consumer. |

Run `mix deps.unlock --check-unused` after every dependency deletion wave.

## Test inventory

### Retain

- parser/analyzer/evaluator/runtime/sandbox/resource tests;
- table-driven Clojure/Babashka conformance and documented gaps;
- new Kernel contract integration matrix;
- workflow/mission confinement and transactional evaluation-memory tests;
- opaque Program capture, non-interpolation, mission-only resolution, source
  bounds, and dynamic/static evaluation parity;
- component dependency/`requires` tests;
- one file capability and one TraceLog/log-prelude integration path;
- thin REPL/runner/viewer/private-transcript E2E paths;
- targeted atom/process/memory/prelude-compile soaks.

### Delete or consolidate

- all SubAgent mode/helper/prompt/validator/compiler tests;
- MCP/upstream/role/store tests with deleted systems;
- evaluator/A-B/oracle/report tests after re-home condition;
- helper-level tests that mirror implementation branches;
- duplicate cases already covered by conformance/integration;
- prompt/presentation snapshots intended to remain replaceable;
- old example, Livebook, demo, metrics, and trace-representation tests;
- obsolete test support such as SubAgent helpers, type-extractor fixtures, and
  public-Step assertions.

## Verification checklist per deletion wave

- [ ] Focused contract/integration tests pass.
- [ ] `mix precommit` passes.
- [ ] `rg` finds no stale module/option/task/config/environment references.
- [ ] ExDoc extras/module groups/package files contain no deleted paths.
- [ ] CI/Mix aliases/releases/Dialyzer apps contain no deleted consumers.
- [ ] Documentation links pass.
- [ ] `mix xref graph` remains acyclic at the configured threshold.
- [ ] `mix deps.unlock --check-unused` passes after dependency changes.
- [ ] Coverage identifies no unexplained retained orphan modules.
- [ ] Inventory rows and exit conditions are updated.
