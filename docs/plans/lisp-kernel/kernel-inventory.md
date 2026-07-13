# Minimal Programmable Kernel — Migration Record

**Status:** implementation and deletion inventory closed on 2026-07-12. This is
the as-built record for the `exp/minimal-kernel` replacement; Git history holds
the removed product implementations and detailed deletion waves.

**Contract:** [`kernel-contract.md`](kernel-contract.md)

**TraceLog contract:** [`tracelog-contract.md`](tracelog-contract.md)

**Sequence:** [`kernel-migration.md`](kernel-migration.md)

## Final classification

- **retained** — surviving language, sandbox, conformance, or tooling foundation.
- **implemented** — contract behavior owned by the new Kernel path.
- **migrated** — retained behavior moved to the named destination.
- **deleted** — removed with its last old-product consumer.
- **superseded/deferred/ignored** — explicitly resolved without a competing
  runtime path.

## Source inventory

### PTC-Lisp and sandbox

| Area | Class | Retained behavior / destination |
| --- | --- | --- |
| `lib/ptc_runner/lisp.ex` | migrated | Kernel uses neutral `Lisp.Result`, `Lisp.Context`, `Lisp.Tool`, signature, and metadata boundaries; journal, agent-budget, discovery-executor, catalog-op, and upstream-specific options are removed. |
| `lib/ptc_runner/lisp/parser*`, `fast_parser*`, AST/source modules | retained | Parsing and source representation. Exact inner source spans remain a language-quality enhancement, not a Kernel migration gate. |
| `lib/ptc_runner/lisp/analyze*` | migrated | Retains static safety and Clojure semantics; agent budget/journal and MCP/catalog discovery surfaces are removed. |
| Parser/analyzer `program` support | implemented | Captures bounded forms without workflow evaluation/resolution, with opaque source identity and no general collection quote/macros. Exact inner spans are deferred. |
| `lib/ptc_runner/lisp/eval*`, `runtime*`, `env*` | migrated | Retains closures/functions/interop/definitions behind a neutral evaluation context; agent, upstream, journal, discovery-op, and catalog-op state is removed. |
| `Lisp.Eval.ParallelRunner`, `ParallelBudget`, `pmap`/`pcalls` workers | migrated | Bounded parallel data execution remains; provider calls have separate atomic live-task limits and concurrent `kernel-eval` returns recoverable `:busy`. |
| `lib/ptc_runner/lisp/retained_size.ex` | retained | Evaluation-memory and capability-result size enforcement. |
| `lib/ptc_runner/lisp/format*`, `formatter*`, keyword representation | retained | Deterministic Lisp formatting and keyword boundary. |
| `lib/ptc_runner/lisp/registry*`, language/spec validation | retained | Language reference and conformance. Remove agent-specific registrations only. |
| `lib/ptc_runner/lisp/discovery.ex` | deleted | Replaced by environment-local `cap/list` and `cap/describe` capabilities. |
| SubAgent budget/plan/journal special surfaces in Lisp | deleted | Replaced by generic runtime usage and workflow annotations. |
| `*1`, `*2`, `*3` support | migrated | Retained for direct REPL history; agent history is ordinary workflow data. |
| `return` / `fail` | retained | Workflow-neutral terminal control signals. |
| `lib/ptc_runner/sandbox.ex` | implemented | Process isolation, timeout, heap, and cleanup accept a neutral context term and use Lisp-owned process propagation; public Context/MCP type coupling is removed. |

### Prelude foundation and deployment platform

| Area | Class | Retained behavior / destination |
| --- | --- | --- |
| `lib/ptc_runner/lisp/prelude/compiler.ex` and compiler helpers | migrated | Retains protected namespaces, exports, compilation, and strict generic `tool:<name>` requirements; upstream inference and provider refs are removed. |
| `lib/ptc_runner/lisp/prelude/bundle.ex` | migrated | Become explicit bounded component-ID DAG `compile_bundle/1` with frozen provenance. |
| Protected namespace/export/prompt inventory primitives | retained | Split workflow/mission validation and mission-only model inventory. |
| `priv/preludes/agent/*.lisp` | deleted | Replaced by Kernel library components `agent.native`, `agent.core`, `agent.feedback`, `agent.retry`, `workflow.event`, and `result`. |
| `PtcRunner.PreludeRolePolicy` and grants | deleted | Roles remain an optional future environment-builder adapter. |
| `PtcRunner.PreludeRuntime` | deleted | Kernel accepts frozen bundles/environments. |
| `PtcRunner.PreludeStore*` | deleted | V1 has no mutable/versioned runtime store. |
| `PtcRunner.PreludeCandidate` | deleted | V1 has no live active-bundle editing. |
| Store/form-edit tools and churn soaks | deleted | Candidate authoring/promotion is deferred and host-gated. |

### New Kernel path

| Area | Class | Retained behavior / destination |
| --- | --- | --- |
| `Kernel.Capability` responsibility | implemented | Host-owned metadata/callback representation selected only through the Slice 8 trusted provider registry. |
| `Kernel.WorkflowEnvironment` | implemented | Frozen workflow capability/data map with attested-bundle and recorded tool-requirement validation. |
| `Kernel.MissionEnvironment` | implemented | Structurally distinct mission capability/data map with attested-bundle validation and no workflow-route merge path. |
| `Kernel.Limits` | implemented | Slice 1: normalized positive hard ceilings. |
| `Kernel.RunState` | implemented | Atomic deadline, counters, protocol exhaustion, serialized evaluation-memory lease, late-provider completion, closed status, and explicit teardown. Event drops remain owned and reported by the bounded sink. |
| `Kernel.Dispatcher` | implemented | Validation, atomic reservation/completion, remaining-deadline timeout, fault containment, bounds, uniform envelopes, and workflow/mission Lisp wiring. |
| Host provider-registry interface | implemented | Host-owned name-to-builder map; manifests can select names but never register executable code. |
| `Kernel.EventSink` responsibility | implemented | Canonical bounded owner-monitored memory sink integrated with run lifecycle and TraceLog. Normal queue loss or sink failure is contained and reported; private exhaustion/failure returns `:event_sink_error`. Persistent JSONL append is an explicit host operation rather than a second live owner. |
| `Kernel.Result` / `Kernel.Error` | implemented | Only public Kernel outcomes. |
| `Kernel.compile_bundle/1` | implemented | Bounded component-ID DAG, deterministic ordering, dependency compilation, attested frozen artifacts, source hashes/provenance, tool-requirement validation, and independent source/time/heap/artifact/diagnostic ceilings. V1 records generic `tool:<name>` requirements rather than provider-specific schemas. |
| Bundle compilation limits | implemented | Component/edge/source/time/heap/artifact/diagnostic ceilings independent of the run deadline. |
| `Kernel.run/2` | implemented | Typed explicit configuration, bounded entry execution, attested workflow bundles, lifecycle cleanup, terminal-result bounds, canonical V1 events, and workflow capability dispatch. |
| Reserved `kernel-eval` | implemented | Slice 4 implemented: workflow-to-mission source and embedded-Program routes, serialized leases, transactional memory, mission-only capability dispatch, remaining-run timeout enforcement, and canonical evaluation/capability events. |
| Opaque Program value | implemented | Static opaque source identity with byte size/digest, analyzer capture, embedded evaluation route, bounded public projection, no workflow-local capture, and shipped helpers. Exact inner spans are deferred. |
| `kernel/eval` / `kernel/eval-source` prelude | implemented | Shipped explicit embedded versus dynamic helpers over one discriminated `kernel-eval` capability; errors remain recoverable values. |
| Generic runtime usage/remaining | implemented | Shipped read-only helpers over changing enforced-resource snapshots. |
| Capability discovery | implemented | Shipped environment-local `cap/list` and `cap/describe` helpers with bounded sanitized metadata. |
| Workflow annotation | implemented | Shipped bounded helper emitting host-stamped `workflow-annotation` events without lifecycle authority. |
| `Kernel.FileCapability` / `fs` library | implemented | Slice 6 deterministic proof: host-held read root, exact argument schema, relative-path and symlink confinement, pre-read/result bounds, UTF-8 results, mission-only discovery, and no ambient workflow filesystem route. |
| `Kernel.LLMCapability` / `llm` library | implemented | Slice 7 provider-neutral workflow capability with host-owned requester, request/response bounds, sanitized transport errors, JSON normalization, generic Kernel quotas/events, and no model policy in BEAM. |
| Shipped agent/result libraries | implemented | Slice 7 strict native action parsing, message loop, correction feedback, retry/backoff decisions, annotations, and opt-in uniform results; scripted tests cover success, prose/protocol correction, evaluation correction, explicit failure, provider failure, and quota exhaustion. |
| `Kernel.Manifest` / `RunBuilder` | implemented | Slice 8 strict duplicate-aware versioned JSON loader, manifest-relative confined sources/input, separate frozen bundles/environments, normalized limits/events/labels, generated qualified entry expression, and one shared build/run path. |
| `Kernel.ProviderRegistry` | implemented | Host-owned `llm`/`file-read` builders plus non-replacing embedder extensions; manifests select bounded names/config only and destination checks reject authority expansion. |
| `mix ptc.run` | implemented | Thin Slice 9 frontend over `RunBuilder`, with JSON output, a confined manifest-relative `--mission` input override, and explicit bounded JSONL trace persistence through `--trace`. |

### Experimental Kernel implementation (closed at public cutover)

| Area | Class | Retained behavior / exit condition |
| --- | --- | --- |
| `lib/ptc_runner/kernel.ex` | implemented | Cut over to the contract-only `compile_bundle/1` and `run/2` surface; bounded execution is owned by the internal `Kernel.Runner`. |
| `lib/ptc_runner/kernel/state_handle.ex` | deleted | Atomic evaluation-memory ownership is implemented by `RunState`; the experiment handle and tests were removed. |
| `lib/ptc_runner/kernel/inner_prelude.ex` | deleted | Frozen environment/bundle requirement validation superseded the role-specific experiment module. |
| `lib/ptc_runner/kernel/action.ex` | deleted | Parity is proven in shipped `agent.native`; the legacy Elixir parser and tests were removed. |
| `lib/ptc_runner/kernel/eval.ex` and `kernel/eval/*` | deleted | Transcript persistence/privacy moved to the shared REPL/TraceLog path. The benchmark runner, datasets, oracle/scoring, comparisons, reports, tasks, and tests were intentionally retired without a compatibility replacement. |
| `lib/ptc_runner/kernel/feedback_ab.ex` | deleted | Removed with A/B variants, task, tests, and generated reports. |
| `priv/kernel_feedback_variants/` | deleted | Removed with the feedback A/B harness. |

### SubAgent and surrounding platform

| Area | Class | Destination |
| --- | --- | --- |
| `lib/ptc_runner/sub_agent.ex` and `sub_agent/**` | deleted | Removed without a compatibility facade after Kernel cutover. |
| SubAgent definitions, validation, compiler, chaining, child agents | deleted | Shipped Lisp libraries and Kernel capabilities own retained behavior. |
| Text/JSON modes, code-fence/JSON recovery, combined transports | deleted | LLM is one generic workflow capability; policies live in Lisp. |
| Prompt expansion, Mustache templates, prompt modes | deleted | Workflow/prelude functions construct prompts. |
| Compaction, plan/progress, journaling, completion modes | deleted | No retained product caller remained. |
| Built-in grep and exposure/native-preview machinery | deleted | Capabilities/preludes replace these. |
| LLM registry inheritance and SubAgent retries | deleted | The trusted provider registry builds workflow capability; retry policy lives in Lisp. |
| `priv/prompts/` | deleted | Kernel agent libraries under `priv/preludes/kernel/` are the retained model policy. |

### Public data abstractions

| Area | Class | Retained behavior / destination |
| --- | --- | --- |
| `PtcRunner.Step`, `Step.Public` | deleted | Native ownership moved to `Lisp.Result`; public execution is Kernel Result/Error. |
| `Kernel.ReplSession` | implemented | Direct bounded evaluator continuation for definitions and `*1`/`*2`/`*3`, with transactional memory, Dispatcher-backed workflow capabilities, manifest configuration, and canonical session events. |
| `PtcRunner.Session` | deleted | Retained REPL behavior lives in `Kernel.ReplSession`; old public/upstream/legacy-TraceLog semantics were removed. |
| `PtcRunner.Context`, `PtcRunner.Turn` | deleted | The evaluator context moved to neutral `Lisp.Context`; the old Turn type had no surviving caller. |
| `PtcRunner.Evidence*` | deleted | No current Kernel/TraceLog contract required the product-specific evidence projection. |
| `PtcRunner.Schema` / generated `priv/ptc_schema.json` | deleted | The obsolete SubAgent JSON protocol schema had no Kernel caller; manifest/capability validation is owned by typed Kernel constructors. |
| `PtcRunner.PtcToolProtocol` | deleted | Native action policy moved to Lisp; the Kernel capability contract replaces it. |
| `PtcRunner.Tool` | deleted | Neutral direct-evaluator normalization lives in `Lisp.Tool`; Kernel providers use `Capability`. |
| `PtcRunner.Template`, `Mustache`, `Temporal` | deleted | Removed with their last agent-mode consumers. |
| `PtcRunner.Chunker` | deleted | No independent language/Kernel consumer remained. |

### Remaining root modules and cross-cutting runtime

| Area | Class | Retained behavior / destination |
| --- | --- | --- |
| `PtcRunner.PreludeOrigin` | deleted | Kernel components use bounded explicit binary origins; the unreferenced product-specific sanitizer was removed. |
| `PtcRunner.Lisp.SampleFormatter` | deleted | The unreferenced presentation helper was removed; public Kernel projection owns result boundaries. |
| `PtcRunner.SymbolInventory` | deleted | Kernel capability discovery derives bounded model-visible metadata directly from the selected environment. |
| `PtcRunner.Lisp.TraceContext` | deleted | Canonical IDs live in RunState/events; evaluator child metadata uses a narrow process-local `Lisp.ChildResult`. |
| Environment loading | migrated | CLI/provider configuration reads explicit environment values; no ambient Kernel authority or separate Dotenv product module remains. |
| `PtcRunner.PromptLoader`, `PtcRunner.Prompts` | deleted | Removed with compiled SubAgent prompt files and last callers. |
| LLM integration | migrated | `Kernel.LLMCapability` and the trusted registry adapt ReqLLM; agent policy remains in Lisp. |

### LLM integration

| Area | Class | Retained behavior / destination |
| --- | --- | --- |
| ReqLLM adapter | migrated | The built-in trusted `llm` provider implements uniform `llm/request` capability semantics. |
| Provider transport normalization | migrated | Bounded provider-neutral data and safe metadata. |
| Model-name resolution | migrated | `ReqLLM.ModelRegistry` resolution remains behind the built-in `llm` provider builder; manifests cannot name modules/functions or replace builders. |
| Structured output, text/tool mode switching, prompt caching wrappers | deleted | Policy lives in Lisp or is deferred. |
| Streaming | deferred | V1 non-goal. |

### TraceLog and viewer

This area is governed by [`tracelog-contract.md`](tracelog-contract.md).

| Area | Class | Retained behavior / destination |
| --- | --- | --- |
| Canonical TraceLog event/envelope | implemented | `Kernel.TraceLog` strictly validates the bounded V1 Kernel event schema, version, run/trace identity, sequence order, JSON data, and timestamps before derivation. The viewer canonical routes now delegate to this implementation. |
| JSONL persistence | implemented | Admin-owned append/reload preserves canonical order under aggregate byte and descriptor-identity checks. Runtime collection remains the bounded event owner. |
| Private transcript sink | implemented | Explicit private `EventSink` policy plus reserved-suffix private JSONL paths fail closed and require separate grants. The experiment harness was retired. |
| `Kernel.TraceLog` / `Kernel.TraceCapability` | implemented | Shared source-scoped memory/file/directory loading, required run metadata, run/turn filters, counters, deterministic result-bounded pagination, source/query-bound cursors, duplicate-key rejection, reserved-suffix private-source confinement, explicit private grants, and uniform capability failures. |
| Legacy `TraceLog.Introspection` | deleted | Remaining callers moved to `Kernel.TraceLog`; the parallel query implementation was removed. |
| `log.core` prelude | implemented | Shipped swappable mission prelude over four explicitly granted trace-query capabilities; missing grants fail during environment assembly and workflow inheritance is structurally absent. |
| `TraceLog.Analyzer` | deleted | Canonical viewer routes and `Kernel.TraceLog` superseded it. |
| Trace memory sink | implemented | `Kernel.EventSink` is the bounded in-memory source for Kernel runs, REPL integration, tests, and `log.core`; legacy sinks were removed. |
| `Tracer`, `Tracer.Timeline` | deleted | The viewer uses canonical Kernel events; the competing in-memory trace representation was removed. |
| `Metrics.Statistics`, `Metrics.TurnAnalysis` | deleted | No retained Kernel or experiment caller remained. |
| `PtcRunner.Kino.TraceTree` | deleted | Removed after the public Step/Turn trace tree was superseded. |
| `ptc_viewer/` | retained | Per-instance host adapter delegates bounded run/turn/counter routes and the primary UI to shared `Kernel.TraceLog`; ordinary discovery excludes reserved private traces. Legacy agent/plan fallback is removed; Interactive Lab is deferred. |

### Upstream and MCP

| Area | Class | Destination |
| --- | --- | --- |
| `lib/ptc_runner/upstream/**` | deleted | A standard capability provider is the extension seam; no anticipatory generic adapter remains. |
| `mcp_server/` | deleted | An optional MCP frontend may return later over the shared manifest/run builder. |
| MCP/OpenAPI transports, credentials, catalogs, discovery | deleted | Modules, tests, sibling package, Docker workflow, and release coupling were removed. |
| REPL upstream flags/catalog modes | deleted | Removed from `mix ptc.repl`; the task uses explicit shared manifest/environment grants. |

## Mix tasks

| Task | Class | Destination |
| --- | --- | --- |
| `ptc.repl` | implemented | Small direct bounded Lisp REPL with transactional definitions/history, scripts/setup files, shared manifest workflow grants, Dispatcher routing, and optional canonical JSONL persistence. |
| `ptc.run` | implemented | Thin shared manifest/run-builder frontend. |
| `ptc.viewer` | retained | Read-only trace/transcript frontend in V1. |
| `ptc.validate_spec`, `ptc.update_spec_checksums`, `ptc.gen_docs` | retained | Retain language/spec maintenance. |
| `ptc.conformance_report`, `ptc.clojure_audit`, `ptc.audit_upstream` | retained | “Upstream” means the Clojure reference runtime, not the deleted network-upstream product. |
| `ptc.smoke`, `ptc.install_babashka` | retained | Retain while conformance uses Babashka. |
| `bench.check` | migrated | Small deterministic runtime regression corpus. |
| `parallel_workers` | deleted | Removed with its example. |
| `ptc.kernel_feedback_ab` | deleted | Removed with the A/B harness. |
| `ptc.kernel_eval` | deleted | Removed at public cutover; optional comparisons must use the shared manifest runner rather than a second Kernel product. |
| `ptc.dna` | deleted | The final duplication audit ran; the temporary task and `ex_dna` dependency were removed. |
| release/smoke tasks | migrated | Reduced to checks for shipped language, Kernel, and viewer artifacts. |

## Top-level directories and assets

| Path | Class | Exit/destination |
| --- | --- | --- |
| `lib/`, core `test/` | migrated | Follow per-area rows; remove obsolete support/fixtures vertically. |
| `config/`, `.env.example` | migrated | Contains only Kernel/provider/frontend defaults; SubAgent, MCP/upstream, demo, and obsolete release configuration is removed. |
| `priv/` | migrated | Contains language/spec data and Kernel Lisp libraries; prompts, variants, and obsolete schemas are removed. |
| `docs/guides/` | migrated | Extract concise Kernel, capability/prelude, TraceLog, REPL/runner docs first. |
| `docs/conformance/`, specification, function reference, conformance gaps | retained | Retain. |
| private experiment transcript plan | superseded | Relevant fail-closed requirements are retained in the Kernel and TraceLog contracts; the experiment/scoring document and harness were retired. |
| old future/archive plans | deleted | Rejected-system plans were removed; Git history remains the archive. |
| `docs/guidelines/` | migrated | Active repository rules were consolidated into `AGENTS.md`. |
| `examples/` | deleted | The unique paged-prelude mechanism was retained as a focused integration fixture. |
| `demo/` | deleted | Deterministic Kernel scenarios and the optional live-provider gate replace the old benchmark product. |
| `livebooks/` | deleted | The obsolete notebooks and Kino test harness were removed. |
| `blog/`, `images/` | deleted | Website assets are no longer packaged in this runtime repository. |
| `reports/kernel_eval/` | deleted | Generated experiment reports and trace fixtures were removed with the evaluator harness. |
| `bench/` | migrated | Small domain-blind deterministic corpus and baselines only. |
| `scripts/` | migrated | Keep active release/repository automation for retained product. |
| `.github/` | migrated | Remove demo/MCP/examples/old docs jobs; retain conformance/Kernel/viewer gates. |
| `.githooks/` | migrated | Contains only retained prepush/precommit/release checks. |
| root README/CHANGELOG/package metadata (`mix.exs`, `mix.lock`) | migrated | Describe and package only the retained language, Kernel, runner/REPL, and viewer integration. |
| `AGENTS.md`, `CLAUDE.md`, `usage-rules*`, licenses/REUSE files | retained | Retain canonical repository/dependency instructions and licensing; update stale product references only. |
| formatter/Credo/Dialyzer/link-check/Docker control files | migrated | Remove deleted paths and dependencies; retain checks required by the final package/frontends. |
| `conformance_inventory.json` | retained | Retain with language conformance tooling. |
| `priv/plts/`, `_build/`, `deps/`, `tmp/`, `erl_crash.dump` | ignored | Not architecture or tracked product content. |

## Dependencies

| Dependency | Class | Condition |
| --- | --- | --- |
| `jason`, parser/runtime dependencies | retained | Retain. |
| `stream_data` | retained | Retain for language/property tests. |
| `req`, `req_llm` | migrated | Retained for the optional standard LLM provider. |
| `telemetry` | retained | Used by the neutral Lisp execution instrumentation and its tests. |
| `ptc_viewer` path dependency | retained | Retain dev/test integration. |
| `kino` | deleted | Removed with Kino/Livebooks. |
| `ex_dna` | deleted | Removed after the final duplication audit. |
| `recon` | retained | Used by active memory-soak support and diagnostics. |
| `benchee` | retained | Used by retained deterministic benchmark/profile scripts. |
| MCP/upstream-only dependencies | deleted | Removed with the last transport consumer. |

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

## Final verification checklist

- [x] Focused contract/integration tests pass.
- [x] `mix precommit` passes.
- [x] `rg` finds no stale module/option/task/config/environment references.
- [x] ExDoc extras/module groups/package files contain no deleted paths.
- [x] CI/Mix aliases/releases/Dialyzer apps contain no deleted consumers.
- [x] Documentation links pass.
- [x] `mix xref graph` remains acyclic at the configured threshold.
- [x] `mix deps.unlock --check-unused` passes after dependency changes.
- [x] Coverage identifies no unexplained retained orphan modules.
- [x] Inventory rows and exit conditions are updated.
