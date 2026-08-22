# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Changed

- `ptc help transcript` and `ptc docs debug` now state both `--private-output`
  destination rules before they can be violated: the parent must exist without
  a symbolic link (macOS `/tmp` is one), and it must be physically separate
  from `--traces` and `--inspection`. The CLI and REPL references match.
- The materialized `debug-a-failed-run` README walks the standalone path:
  `ptc run` for every arm, and a documented `--component-override-descriptor`
  recipe that states it skips the host-owned G1–G4 gate. Checkout-only Mix
  commands and `examples/` paths are gone from that README.
- `ptc docs designing-agent-workflows` now says `returned-value` and
  `quarantined` are local helpers in the support-triage example, not shipped
  built-ins.

- `mix precommit` is nested fetch plus the quality scripts. The suite, Viewer,
  launcher package, and release verification run on `git push` (and in GitHub
  Actions), so an agent that already ran `mix precommit` should not follow it
  with `git push --no-verify`: pre-push still adds Dialyzer and ExDoc.

### Added

- Dev and test builds pin published `ptc_llm_http` `0.1.0` for loopback
  streaming compatibility coverage. The package is not a production runtime
  dependency and is not selected for ordinary requests.
- ptc-runner.dev now publishes the pinned MCP 2026-07-28 wire schema at
  `/schemas/mcp-2026-07-28.schema.json`, which is what a third-party author
  needs to write a server PtcRunner can acquire. It is upstream's document
  with two corrections PtcRunner maintains, both stated in the file. The MCP
  reference names the discovery, tool-list, tool-call, and error definitions a
  server must satisfy, and records the narrower result policy PtcRunner
  enforces on top of them.
- ptc-runner.dev now serves the guides, installation routes, and reference
  documentation as generated pages under `/guides/`, `/installation/`, and
  `/reference/`, behind a sectioned sidebar that is also spliced into the
  landing page. The sections are read from the same `mix.exs` groups that
  structure the HexDocs sidebar, so the two navigations cannot drift.
  `mix ptc.gen_site_guides` renders the pages (and `mix ptc.gen_docs` runs
  it); the renderer fails closed on Markdown, attributes, or relative links
  it cannot account for, and every internal fragment link is validated down
  to the anchor, so a typo cannot ship as a dead link.
- A new Language guide, "Read and write PTC-Lisp" (`docs/guides/
  ptc-lisp-basics.md`): a ten-minute REPL tour of values, calls, maps,
  collections, truthiness, recoverable errors, and function definitions.
  Every `; =>` example is validated against the interpreter by a test, and
  the REPL transcripts show real captured output.
- Added `mix ptc.repair` to consume one structured generated `propose-change`
  repair report, bind it to the current component base hash, and pass the
  existing G1-G4 materialization gate. Optional live trials require an explicit
  effects acknowledgement and a host-owned suite of exact normal or private
  inputs and expected results; reports never control paths, credentials,
  inputs, host configuration, effect-widening acceptance, or promotion.
- Added `agent.core/run-phased-result-value`: an agent run can declare ordered
  mission phases under one turn ceiling, retaining the exact correlated
  transcript while the host swaps mission authority between phases. A return
  in a non-final phase becomes retained evidence; a `terminal_only` phase
  rejects any program that is not a single top-level `return` or `fail` before
  evaluation.
- The `debug-a-failed-run` example closes the loop it documents: a phased
  repair agent reads the incident packet the host acquires before model turn
  one and completes through one typed terminal action — a complete component
  replacement or an abstention. `mix ptc.repair` validates a proposal against
  host-owned held-out cases, and the validated candidate reruns the failed
  target green via `--component-override-descriptor` without editing a file.
  A second, deliberately underdetermined target demonstrates the abstain arm.

- `ptc viewer PROJECT.json` opens the canonical trace Viewer from both the
  `mix ptc` and standalone frontends, replacing the development-only
  `mix ptc.viewer` task. The Viewer now ships inside the assembled release and
  the container image, so a packaged install can browse the traces it records;
  the published Hex package still does not carry it, and the command reports
  the companion as unavailable there.
- The command binds `127.0.0.1` and accepts `--listen 0.0.0.0` as the only
  other address, warning when it is used: the Viewer is unauthenticated and can
  display private inspection records. Inside a container that wildcard is what
  a published port can reach, and `docker run -p 127.0.0.1:PORT:PORT` is what
  keeps host exposure on loopback. `--port` overrides the project's port.

### Changed

- Host examples, tutorials, and MCP e2e tests now pin the published
  [`ptc-fs-mcp@0.1.0`](https://www.npmjs.com/package/ptc-fs-mcp) package instead
  of the two in-repo sample servers. Reads and writes share live bytes, so a
  write is visible to the next read. Operator hosts launch it with `npx`;
  hermetic tests spawn absolute `node` against the installed `dist/cli.js`.

### Removed

- `examples/mcp/filesystem` and `examples/mcp/writer`, their committed Node
  bundle and `NOTICE`, and the CI job that rebuilt that bundle on every sample
  change.

### Fixed

- Private analysis sessions now admit bounded pre-execution diagnostics
  (`:parse_error`, `:invalid_arity`, `:invalid_form`, symbol/compile limits,
  and tool-resolution faults) when no capability has run in that evaluation.
  An arity mistake such as `(defn foo)` reports the analyzer's fixed message
  instead of the private-result redaction, while post-capability faults of the
  same kind remain withheld.

- MCP stdio now retains bounded child stderr in the private inspection
  artifact, so operator diagnostics that a well-behaved server can only put on
  stderr are no longer dropped after the launcher captures them. Overflow from
  the launcher is marked truncated, captured exchanges are serialized so stderr
  stays with one request, and a split UTF-8 sequence is held until it completes.
  A complete decoded MCP refusal or JSON-RPC error is no longer reported as
  `mutation_state: "indeterminate"` for write tools; that flag stays reserved
  for timeouts and other unknown outcomes.

- Reconstructed conversations carry the `system` prompt that shaped each turn,
  so `ptc transcript` and the Viewer's conversation view no longer certify a
  transcript as complete while omitting the instructions the run was given.
  Each returned page is compacted on its own, after filtering and pagination,
  so every stream in a page starts with its effective prompt while an unchanged
  prompt is not repeated on every turn. Stream linkage keys on request messages
  alone, so an elided `system` means "unchanged since the last turn in this
  page that carried one" rather than "none was sent".

- A run listing or counters query now reports the trace files its source kind
  refused to read, as `excluded_private_trace_files` or
  `excluded_sanitized_trace_files`. A project whose traces are all private no
  longer answers an empty Viewer run list as though no runs existed; the run
  picker names the exclusion and the `viewer.private` setting that reads them.
  `omitted_count` keeps its single pagination meaning.

- Raised capability callbacks now retain their bounded exception class,
  message, and formatted stacktrace only in explicitly enabled private
  inspection. Inspection V7 correlates that sensitive evidence with the
  capability attempt. When retention succeeds, the Lisp result and canonical
  event stream keep the existing closed `provider_error / exception` envelope;
  a required private-inspection retention failure remains fail-closed as
  `inspection_sink_error`.

- MCP endpoint connection refusal, unresolved names, and admitted TLS handshake
  failures now retain distinct closed diagnostics through acquisition and tool
  invocation without exposing dependency or endpoint details. Dual-stack
  endpoint connects race a bounded 16-address set under one deadline, preserve
  not-dispatched provenance, and fall back across OAuth-approved addresses;
  authorization-server discovery and token traffic remain generic.

- Private inspection now retains an authenticated `result_contract_failed`
  diagnostic instead of destroying it. The retained runtime details carry
  internal contract-authority and command-path structs, which are not JSON
  inspection values; emitting them poisoned the inspection sink and replaced
  the real outcome with `inspection_sink_error`, so the run most in need of
  debugging lost its own evidence. Only the inspection copy is projected — the
  attestation is dropped and each already-authorized path is rendered as a JSON
  Pointer — while the runtime error keeps its authenticated structs unchanged.

- Replaced eager `cap/collect-pages` with resumable `cap/fold-pages`, which
  reduces pages into bounded caller state, preserves the next cursor at a page
  bound, and rejects changed snapshots or cursor cycles.

- Analysis and trace snapshot pagination now treats the caller's item limit as
  an upper bound and returns the largest prefix whose complete encoded and
  retained sizes fit the configured result ceiling. Large private model
  exchange histories therefore remain pageable instead of being rejected by
  the capability boundary after the query layer accepted them.

### Added

- Added the shipped `debug.nav` component: `runs`, `open`, `read`, and a safe
  `follow` over one immutable run-evidence capture. `follow` takes a typed
  relationship exactly as an evidence item published it, refuses an unavailable
  or filterless one, and returns the relationship beside the unchanged native
  page envelope so cursors, completeness, and relationship state survive the
  hop. It adds no host authority and no diagnosis policy.

- Added the [Debug a failed run](docs/guides/debugging-a-failed-run.md) guide
  and its credential-free `examples/debug-a-failed-run` pair, in which one
  ordinary PTC run navigates another run's captured failure from the boundary
  error through generated source and referenced prelude source to the frozen
  dependency closure.

- Added occurrence-qualified `dependency_prelude_source` relationships to
  effective prelude sources, so a debugger can walk a frozen dependency closure
  instead of guessing which copy of a shared component a call reached. A
  component ID alone is not an occurrence identity, so every edge repeats its
  environment and, for a mission occurrence, its mission name. The edges are
  derived only from a prelude graph
  that satisfies the complete positional contract — indices aligned with unique
  component IDs, each row unique, ascending, and strictly earlier than its own
  position — and any other graph yields one honest `incomplete` relation.

- Generated entries embedded in `turns` now carry the same `relationships` list
  as the matching `generated_sources` item. A generic walker that starts from a
  turn no longer needs an extra exact read by `evaluation_id` merely to obtain
  followable links.

- Added typed, followable run-analysis relationships from workflow boundary
  errors to directly proven child producers, generated source, producing turns,
  and referenced prelude source. Each relation supplies an exact target
  collection/filter pair plus causation, nesting, or association semantics and
  an explicit complete, incomplete, ambiguous, or unavailable state; collection
  descriptors now name their snapshot and sequence domains and identifier paths.

- Added canonical parent-evaluation edges for workflow-launched mission
  evaluations. Private generated-source and turn projections preserve the edge,
  and `activity`, `generated_sources`, and `turns` accept exact
  `parent_evaluation_id` filters so debuggers can navigate from a workflow error
  to its child programs without comparing unrelated snapshot sequences.

- Replaced the split log/inspection analysis vocabularies with the three-operation
  `analysis/runs`, `analysis/open`, and `analysis/read` navigation API shared by
  PTC-Lisp, the Viewer, Elixir embedders, and the one-shot `ptc transcript`
  command. `open` advertises the available public and private collections; `read`
  returns their native bounded pages without adding diagnosis policy.

- Added the fixed, mission-only `ptc_private_trace_snapshot` provider source.
  It immutably captures ordinary and private canonical traces with per-run
  provenance, keeps inspection artifacts excluded, and classifies the run as
  `private_inspection`. The private run-analysis profile now accepts
  private traces recursively while preserving V6 terminal-result hash
  correlation; ordinary trace readers remain normal-only.

- Added exact successful terminal-result inspection for explicitly private
  captures. Inspection V6 binds one strictly JSON `run-result` record to the
  canonical `run-stopped.data.result_hash`; `analysis/open` exposes the
  value and hash through the bounded private analysis profile, while ordinary
  traces retain only the hash. V6 also correlates each analyzable generated
  program with its sorted static prelude calls and owning component IDs.

- Added explicit named mission environments: manifests declare a bounded
  `missions` map with isolated data, continuations, APIs, and provider grants;
  workflow and agent APIs select missions by name; V2 traces, V6 inspection,
  Viewer projections, and stable command V2 evidence preserve mission
  attribution. The reader/writer example demonstrates two least-authority
  agents orchestrated by one workflow.

- Added a bounded Java interop oracle baseline with pinned Temurin and JVM
  Clojure versions, typed fixtures for every admitted overload, exact descriptor
  attestation for every JVM overload, executable closed-dispatch compatibility
  cases, a Babashka fast subset, and a dedicated CI conformance job.
- Added closed manifest dispatch, structured Java failures, native Java
  callables and primitive provenance, bounded boundary projection, and complete
  Java CoreAST nodes; migrated `Boolean/parseBoolean` off its legacy Env route.
  Primitive provenance survives non-numeric Lisp operations, while
  signature-aware recursive projection prevents Java authority from hiding in
  tool arguments, tool results, return validation, or struct fields. Numeric
  arithmetic, numeric index/count, aggregate, and ordering consumers erase
  primitive provenance consistently, including higher-order invocation, while
  native formatting preserves distinct primitive kinds without collapsing
  literal-label map keys or set members. Java callables derive static,
  constructor, or receiver-first instance invocation from manifest identity.
  Numeric index/count projection is overload-arity aware, comparator callbacks
  share callable dispatch and numeric projection, and constructor/direct-dot
  source spellings resolve through the manifest before closed dispatch.
  Java and ordinary struct-shaped maps must contain their exact declared fields.
  Java class spellings are reserved against prelude shadowing, and rejected
  tool results retain their executed callback ledger entry.
- Migrated Java numeric parsers and Double special-value fields to closed
  manifest dispatch. Java-named parsers now preserve exact primitive identity,
  enforce int/long ranges, use direct IEEE float/double rounding, accept Java
  decimal and hexadecimal syntax, and return bounded Java parse conditions;
  unqualified Clojure parsers keep their safe `nil` behavior.
- Migrated selected `java.lang.Math` methods to closed manifest dispatch with
  exact primitive overload selection, Java overflow, signed-zero, NaN,
  infinity, rounding, and saturation behavior. Qualified Math calls are now
  distinct from the generic bare PTC-Lisp math helpers.
- Migrated `System/currentTimeMillis` to closed manifest dispatch with native
  Java `long` identity. The qualified call projects to an ordinary integer at
  public boundaries, and the bare `(currentTimeMillis)` compatibility alias was
  removed.
- Migrated LocalDate, Instant, Duration, and legacy Date to validated native
  wrappers and class-owned closed dispatch. Temporal precision and Java ranges
  survive native evaluation; Date integers are exact milliseconds; public,
  Kernel, formatting, export, retained-size, and signature-aware tool
  boundaries handle every wrapper explicitly. Removed the bare `parse` alias,
  Instant `getTime`, Date `isBefore`/`isAfter`, the Date temporal constructor
  extension, host temporal promotion, and the global temporal dispatcher.
- Migrated admitted `java.lang.String` methods to closed dispatch with bounded
  UTF-16 code-unit semantics while ordinary PTC string helpers remain
  grapheme-based. Oversized or unrepresentable String operations now return the
  documented bounded condition; locale-sensitive `.toLowerCase` and
  `.toUpperCase` and all legacy Java String aliases were removed.
- Added the code-owned `run-analysis-v1` profile to `mix ptc repl`, with
  bounded multi-turn mission evaluation over an immutable trace capture,
  explicit whole-result cursor traversal, deterministic JSONL output for
  coding agents, safe profile discovery, and separate atomic analysis-trace
  persistence. Rejected log and inspection queries now fail instead of looking
  like empty results. The public and private authority recipes reuse the
  shipped `cap` envelope and one semantic analysis component.
- Added one typed MCP source with equivalent stateless Streamable HTTP and
  owned stdio transports. Stdio uses the optional precompiled
  `ptc_runner_launcher` companion, freezes launcher and server digests, and
  provides bounded process-group cleanup.
- Added manifest-relative input and result contracts with a bounded object
  profile and root-only tagged decision unions. Input overrides now validate
  before provider activity, and successful result values validate after
  evidence capture but before terminal or artifact publication.
- Added a host-installed `ptc_trace_snapshot` source that freezes one canonical
  trace directory and exposes the existing four bounded `TraceLog` queries
  under alias-derived mission capability names.

### Changed

- Both `mix ptc` and the standalone `bin/ptc` now load dotenv input only when
  `--env-file FILE` explicitly names the exact file. Ambient parent-directory
  discovery was removed, process environment values still take precedence,
  and missing-credential rendering points to the supported credential sources.
- Added the runtime-included `bin/ptc` command and replaced the separate
  `mix ptc.run` and `mix ptc.repl` tasks with the generic
  `mix ptc <command>` surface. The dotted Mix tasks were removed without
  compatibility shims.
- Removed the unreferenced `diagnostic` and `artifact_state` definitions from
  the published `ptc-command-envelope-v2` schema. Both were emitted but
  referenced by no envelope branch, and `diagnostic` was a union over the whole
  diagnostic catalog, so consumers generating types from `$defs` derived a
  wider diagnostic than any envelope can carry. Validation behaviour is
  unchanged; an out-of-tree `$ref` pointing at either definition must be
  repointed at the per-branch definition it needs.
- The shipped `agent.main/run` entry now validates model-authored terminal
  candidates against the manifest result contract while the bounded loop can
  still request a correction. Rejected values remain withheld; other workflow
  entries retain the final fail-closed publication check.
- `PtcRunner.Lisp.run/2` now retains only statically referenced context keys
  when context filtering is enabled, including scalar grants. Set
  `filter_context: false` when a program requires dynamic or metadata
  passthrough. Public pre-setup errors validate continuation memory inside the
  bounded setup worker before returning it.
- `PtcRunner.Lisp.CoreToSource.serialize_closure/1` and
  `serialize_namespace/1` now return `{:ok, value}` or `{:error, reason}` and
  reject closures, including closure entries selected from a namespace, that
  cannot hydrate losslessly.
- `PtcRunner.Sandbox.execute/3` timeout failures now include `:setup` or `:eval`
  phase metadata and may include a third rollback-snapshot element when a
  configured post-setup failure occurs.
- MCP provider installation now requires a nested `:transport` tuple; the
  former top-level HTTP `:endpoint`, `:headers`, and
  `:allow_insecure_loopback` options were removed.
- Provider resource close functions must now return exactly `:ok`. Any other
  return, exception, or exit is a cleanup failure; all closers are still
  attempted, and a failed cleanup can replace a completed Kernel result with
  `:provider_cleanup_error`. REPL close and abort results retain the frozen
  terminal event batch alongside a cleanup error so trace persistence can
  complete before the frontend reports the failure.
- Made standalone `PtcRunner.Kernel.ReplSession` values process-affine. Only
  the process that creates a session may evaluate, close, or abort it; calls
  from another process now return `:session_owner_mismatch` without mutating
  the continuation or stopping its owners. Public session values no longer
  expose continuation values or raw run-state, sink, provider, or configuration
  capabilities or owner process identifiers. An opaque ID resolves through a
  creator-private table to one internal owner; closed entries are removed and
  the owner closes all resources if the creator exits. Evaluation results now
  use the inert public projection instead of returning native callable
  continuation authority, preflight errors preserve the committed public memory
  view, projection failures roll back before commit, owner construction
  validates the exact run-state/sink/limit binding, and monitor-based watchdogs
  cancel compile and evaluation workers if the creator exits without changing
  its trap-exit flag or retaining an unbounded copy of the workload.
- Redacted `Inspect` output for payload-bearing Lisp results, opaque Kernel
  programs, and runtime callables. Logger messages explicitly built from these
  inspected values now retain only bounded outcome/count/byte metadata, program
  digest identity, and callable bound state instead of source, prompts, memory,
  tool payloads, child steps, or evaluator context.
- Ordinary Kernel runs and standalone REPL sessions now reserve terminal event
  count and measured envelope capacity and atomically freeze one canonical
  batch for result usage, trace, and inspection persistence. Drop accounting is
  capped at sixteen event types plus a saturating overflow bucket, each
  `RunConfig` atomically claims its recorder for one execution, and rejected
  claimants cannot close resources owned by the winning run or REPL session.
- Unified direct and Kernel public-value projection. Direct results preserve
  colliding map keys and set members with inert wrappers, while Kernel JSON
  boundaries reject ambiguous projections with
  `:public_projection_collision` instead of silently dropping values.
- Made tool caching evaluator-local: every PTC-Lisp evaluation starts empty,
  caller-supplied `:tool_cache` state is rejected, and
  `PtcRunner.Lisp.Result` no longer exposes internal cache entries.
- Completed the Java interop migration cleanup. Every admitted overload now
  uses closed dispatch; the temporary `legacy_env` schema, empty Java binding
  catalog, Phase-0 attestation snapshot, and non-Java `Math/` namespace aliases
  were removed. Ordinary PTC functions such as `bit-and` and `trunc` remain
  available only under their non-Java names.
- Replaced the legacy SubAgent, MCP, upstream, mutable-prelude, and trace
  products with the owner-based `PtcRunner.Kernel` runtime.
- Added immutable component bundles, structurally separate workflow and mission
  environments, explicit host capabilities, strict JSON manifests, and shared
  `ptc run` / `ptc repl` construction.
- Added bounded mission evaluation, LLM/file/trace capability libraries,
  generic Lisp-authored agent libraries, and canonical Kernel events.
- Consolidated the Lisp evaluator around neutral contexts and results; removed
  agent journal/budget/progress forms, MCP/catalog discovery, and upstream
  inference.
- Moved canonical trace loading/querying into `Kernel.TraceLog` and updated
  `ptc_viewer` to use it.

### Fixed

- Reconstructed model conversations now treat blank tool-call narration and
  the agent loop's carried-forward `nil` as the same absent content. Private
  debugger traversals therefore retain their stream-local turn numbering while
  preserving exact raw model exchanges.
- Failed private debugger runs now retain validated input-only model and
  capability attempts as explicitly incomplete evidence. Raw reads expose the
  complete prefix without inventing terminal data, while reconstructed turns
  continue to report the interrupted model exchange as missing.
- A fresh-clone `mix ptc` invocation now performs normal dependency validation
  and compiles fetched dependencies before compiling PtcRunner. Warm root
  commands retain the dependency-check startup optimization after the first
  successful application build.
- Command envelope publication no longer suppresses the normal terminal
  rendering. Help, version, and init now use readable code-owned projections,
  while workflow result values retain deterministic JSON rendering.
- Destination failures now preserve their closed trace, inspection, or result
  identity, and destination collisions consistently report actionable argument
  conflicts without exposing caller paths.
- Corrected the debugging and `println` documentation to distinguish dynamic
  REPL setup files from compiled components and provider-backed inspection
  records from evaluation-local `prints` entries.
- Private analysis sessions no longer redact diagnostics built from the
  operator's own submitted source. An undefined-variable failure now reports
  its names, each verified to appear verbatim in the submitted source and
  rebuilt rather than forwarded, so no evaluator text can quote a captured
  record. Every session error map carries `message_redacted?`, and a withheld
  message says that it was withheld.
- `defn-` and `ns` in dynamic source now name their own cause instead of only
  their consequences ("`'defn-' defines a private helper in component source
  only; use defn in dynamic source"), and undefined-variable failures carry the
  names structurally in `details.unbound_names`.
- `mix ptc repl` profile resources whose artifacts sit one directory level down
  are refused with a message that states the rule, instead of capturing zero
  files and answering every query with an empty page. A started session reports
  the admitted file and run counts per resource.
- PTC-Lisp namespace export now uses the shortest round-trippable float
  representation, preventing small finite values such as `1.0e-20` from being
  serialized as zero.
- Hardened public, continuation, tool, Kernel JSON, artifact, and namespace
  export boundaries against malformed wrappers, improper lists, and lossy map
  or set projection collisions.
- Centralized sandbox worker teardown around process aliases and phase-aware
  cleanup so late replies cannot leak into callers and evaluation failures
  retain bounded rollback state.

This is a 0.x replacement release. The deleted APIs have no compatibility
facades.

## [0.13.0] - 2026-06-24

### Breaking Changes

- Slimmed the MCP `lisp_task` activity ledger (removed internal turn and
  args-hash fields from the success overview).

### Added

- Capability Preludes (V1): define and deploy reusable, namespaced PTC-Lisp
  capability libraries — including tool-backed exports — that programs and
  SubAgents can call. Backed by a versioned prelude store with editing tools,
  configurable defaults, and per-session prelude selection (root, MCP, and
  SubAgent). See the authoring & deploying guide.
- Session turn log and introspection: record per-turn session activity and
  query it from PTC-Lisp via the `log/` prelude and `(source ...)` discovery.
- Paged access to large tool results so programs can fold over big payloads
  within the memory budget.
- New PTC-Lisp helpers: `describe`, `doc`, and JSON `parse-lines`.
- SubAgent-to-upstream bridge so SubAgents can call configured upstream tools
  with fail-closed prelude requirements.
- Opt-in session feedback (collection hints) and configurable session
  preview/result caps.

### Changed

- Re-baselined sandbox heap accounting so granted environment data no longer
  counts against a program's memory budget; programs that previously hit the
  limit purely from large grants now run.
- Upstream tool calls apply a default side-effect guard.

### Fixed

- Hardened memory bounds so retained buffers (credential redaction, debug ring,
  trace collector, prelude store) can no longer grow unbounded.
- PTC-Lisp formatting/conformance fixes for regex literals, reader-macro forms,
  and turn-history references (`*1`/`*2`/`*3`).
- Fixed broken cross-references in the published API documentation.

## [0.12.0] - 2026-06-03

### Breaking Changes

- Renamed the upstream tool Lisp surface from the MCP-specific
  `(tool/mcp-call ...)` and `(mcp/servers)` forms to transport-neutral
  `(tool/call ...)` and `(tool/servers)`.
- Tightened upstream configuration transport names. Use `"openapi"`,
  `"mcp_stdio"`, or `"mcp_http"`; older ambiguous names such as `"stdio"` and
  `"http"` are rejected.
- Corrected several PTC-Lisp edge-case semantics for Clojure conformance,
  including `find` as associative lookup, `range` type errors, negative `nth`,
  duplicate literal map/set keys, and arity handling for `assoc`, `juxt`, and
  bitwise helpers.

### Added

- Added the root upstream runtime for embedded Elixir callers and `mix ptc.repl`,
  allowing PTC-Lisp programs to call configured OpenAPI, MCP stdio, and MCP HTTP
  upstream tools without running the MCP server.
- Added read-only JSON OpenAPI upstream support with credential bindings,
  operation allow-lists, schema loading, response caps, and the same tagged
  `tool/call` result model used for MCP upstreams.
- Added `PtcRunner.Session` for embedding stateful REPL-style PTC-Lisp
  evaluation with persistent `(def ...)` memory and bounded `*1`/`*2`/`*3`
  result history.
- Added upstream-aware `mix ptc.repl` options for loading upstream configs,
  listing tools, discovery, call budgets, response caps, and catalog snapshot
  modes.
- Added `mission_log_in: :user_message` format support so agents can keep system
  prompts stable for provider prompt caching.

### Changed

- Moved MCP aggregation onto the shared root upstream runtime, so root callers
  and the MCP server use the same config format, discovery forms, credential
  redaction, and `tool/call` execution semantics.
- Expanded PTC-Lisp Clojure conformance across nil-tolerant sequence helpers,
  multi-collection `map`/`mapv`/`pmap`, variadic `interleave`, three-arity
  `nth`, seq-form `replace`, Java `Boolean/parseBoolean`, and Java Math special
  cases.
- Improved release readiness with deterministic smoke, performance, coverage,
  docs, and package-content checks.

### Fixed

- Authentication is enforced before MCP HTTP method dispatch, required on
  non-loopback binds, rate-limited on failed bearer attempts, and scrubbed from
  traces/log-facing output.
- Upstream MCP result normalization now returns the first text block rather than
  only inspecting the first content item.
- Closed-but-unpruned MCP HTTP sessions now resolve to tombstones instead of
  crashing through a missing process.
- Invalid integer HTTP/MCP configuration values now fail fast with clearer
  errors.

## [0.11.0] - 2026-05-25

### Breaking Changes

- Removed the underscore-prefix context firewall convention. `_`-prefixed
  context keys are now visible like ordinary keys.
- `(tool/mcp-call ...)` now returns tagged result maps directly. Remove uses
  of `mcp/text` and `mcp/json`; check `:ok` and read `:value` instead.

### Added

- Added PTC-Lisp ISO-8601 date-time parsing through `parse`,
  `LocalDate/parse`, and `Instant/parse`.
- Added PTC-Lisp bitwise integer builtins, including `bit-and`, `bit-or`,
  shifts, bit set/clear/flip/test, and `bit-not`.
- Added `(list & args)` as a Clojure-friendly alias for `vector`.
- Added `json/parse-string` and `json/generate-string` to PTC-Lisp.
- Added runtime callable support and unified REPL discovery helpers.
- Added Java duration helpers and namespace conformance audits.
- Added `KeyNormalizer.canonical_cache_key/2` for stable tool-result cache
  keys across atom/string map keys, map order, and integer-equivalent floats.
- Added opt-in `compaction:` support for pressure-triggered multi-turn context
  trimming.

### Fixed

- Improved PTC-Lisp type errors so common argument swaps and builtin values no
  longer leak Elixir internals.
- Preserved `sort-by` key errors and added support for sorting maps and vector
  paths.
- Accepted common `format` width hints.
- Kept compilation clean on Elixir 1.20 release candidates.

## [0.10.1] - 2026-05-04

### Fixed

- `count`, `reduce`, and `assoc` now treat `nil` as an empty collection, matching the nil-tolerance of other collection helpers (#863)

### Changed

- Lockfile refresh: `req_llm` 1.8.0 → 1.10.0 (constraint stays at `~> 1.8`, no consumer action needed)
- Dev tooling bumps: `credo` 1.7.18, `usage_rules` 1.2.6

## [0.10.0] - 2026-03-26

### Breaking Changes

- **MetaPlanner, PlanExecutor, PlanRunner, PlanTracer, PlanCritic removed** — The autonomous planning system with JSON task graphs, verification predicates, and replanning has been removed. Put orchestration and agent policy in PTC-Lisp instead — see [Building agents](docs/guides/building-agents.md).
- Planning prompt templates removed (`planning-examples.md`, `verification-predicate-guide.md`, `verification-predicate-reminder.md`, `signature-guide.md`)
- PlanExecutor telemetry events removed
- Internal `llm_client` package removed — use `PtcRunner.LLM` behaviour directly
- **`plan:` no longer auto-enables `journaling: true`** — Plans are now display-only labels for progress visibility. To use journaled task caching, set `journaling: true` explicitly.

### Added

**Model String Shorthand**

- Accept model strings directly in `SubAgent.run` — e.g., `llm: "haiku"` instead of building an LLM struct

**Clojure Conformance Expansion (~30 new functions/forms)**

- Control flow: `case`, `condp`
- HOF combinators: `comp`, `partial`, `complement`, `constantly`, `every-pred`, `some-fn`
- Collection operations: `cons`, `disj`, `empty`, `merge-with`, `reduce-kv`, `zipmap`, `filterv`, `update-keys`, `peek`, `pop`, `subvec`
- Sequence operations: `split-at`, `split-with`, `partition-by`, `dedupe`, `keep`, `keep-indexed`
- String/coercion: `format`, `name`, `keyword`, `hash-map`
- Type predicates: `int?`, `integer?`, `double?`, `float?`, `fn?`, `false?`, `true?`, `symbol?`, `decimal?`, `ratio?`, `rational?`, `nat-int?`, `neg-int?`, `pos-int?`, `infinite?`, `NaN?`
- Collection capability predicates (`sequential?`, `associative?`, `counted?`, etc.)
- Named fn for self-recursion (`(fn name [x] ...)`)
- `%&` rest args in `#()` short function syntax
- Keyword args via rest destructuring (`[& {:keys [a]}]`)
- `:strs` map destructuring for string-keyed maps
- `def`/`defn`/`defonce` can shadow builtins (Clojure-compatible)

**Java Interop Methods**

- String: `.startsWith`, `.endsWith`, `.toLowerCase`, `.toUpperCase`, `.contains`
- Date/DateTime: `.isBefore`, `.isAfter`

**Prompt System**

- 2-axis composable prompt architecture for flexible prompt composition
- Language reference included in default prompt compositions
- Pluggable `progress_fn` for custom turn feedback rendering

**Tracing**

- JSONL trace format v2 with flat event envelope
- Typed trace headers (`trace_kind`, `producer`, `query`, `model`, `trace_label`)
- Trace analyzer agent for investigating execution traces
- Streaming `query_events` and `aggregate_events` tools

### Fixed

- `keys`/`vals` nil-tolerant (like other collection helpers)
- `concat` type error diagnostics for non-collection args
- Hyphen/underscore normalization in flex_access lookups
- `and` returns last truthy value instead of boolean (Clojure conformance)
- `some` with keyword pred returns extracted value, not boolean
- `defn` inside `let` now visible across program expressions
- Code fence parsing uses line-by-line parser instead of regex
- Runtime exceptions classified as `:runtime_error` not `:tool_error`
- Sandbox-safe `list_traces` with bounded head/tail reads

### Changed

- Progress checklist renders for any agent with a `plan:`, regardless of `journaling:` setting
- `step-done` instruction text updated to reflect it is optional
- Bumped `req_llm` to `~> 1.8`

## [0.9.0] - 2026-02-27

### Added

- `SubAgent.chat/3` for multi-turn chat with conversation history threading
- `on_chunk` streaming callback for real-time token-by-token output in text mode
- `PtcRunner.LLM` behaviour with `call/2` and optional `stream/2` callbacks
- `PtcRunner.LLM.callback/2` convenience API with built-in ReqLLM adapter
- Graceful streaming degradation — `on_chunk` fires once with full content when adapter doesn't support streaming

### Documentation

- LLM Setup guide with provider configuration, streaming, custom adapters, and framework integration
- Phoenix Streaming guide for LiveView integration with `chat/3` and `on_chunk`
- Structured Output Callbacks guide for implementing LLM callbacks
- Added phoenix-streaming and structured-output-callbacks guides to ExDoc
- Updated getting-started guide with chat, streaming, and LLM adapter sections

## [0.8.0] - 2026-02-25

### Breaking Changes

- Renamed JSON mode to text mode — `:json` and `:tool_calling` unified into single `:text` output mode
- Removed backward compatibility shims for old mode names
- Renamed builtin tool names to match new text mode conventions
- Migrated system prompts from markdown headings to XML tags
- Removed `gpt-nano` and `gpt-mini` model entries from LLM registry

### Added

**Unified Text Mode**

- `TextMode` module replacing `JsonMode`, with separate `JsonHandler` for structured output
- Native tool calling mode for smaller LLMs that support API-level tool use
- `ToolSchema` module for generating tool schemas from signatures
- Guard against nil `assistant_content` in tool-call messages

**PTC-Lisp Enhancements**

- `defonce` special form for idempotent variable initialization
- `pr-str` function for readable string representation
- `#"..."` regex literal support
- `CoreToSource` module for Core AST to PTC-Lisp source serialization
- MapSet support for `some`, `every?`, `not-any?`, `join`, `split`, `replace`
- Preserved `tool_calls` and `prints` from inside HOF closures
- Preserved `tool_calls` and `tool_cache` across `loop`/`recur` iterations
- Handle `:var` nodes in `SymbolCounter`
- Handle `#'name` var reader syntax in analyzer
- Handle `defonce` in `collect_undefined_vars` static analysis
- Skip bare vars in `or` during static undefined-var analysis
- Treat unbound vars as nil in `or` for safe memory defaults
- `str` fixed to use Clojure syntax for collections
- Return nil for keyword lookup on non-map types (Clojure conformance)

**SubAgent Improvements**

- `max_tool_calls` limit to prevent runaway tool loops
- `pmap_max_concurrency` config to control parallel task limits
- SubAgent `name` propagated to `Step` for TraceTree and Debug display
- Journal/step-done prompt sections gated behind `journaling: true`
- Moved `defonce` docs from base prompt to multi-turn addon

**LLM Client**

- `embed/2,3` and `embed!/2,3` for embedding API support
- Groq provider support
- Bedrock inference profile support
- Migrated to ReqLLM pricing (removed `LLMClient.calculate_cost`)

**Tracing & Viewer**

- Plan progress display in `Debug` and `TraceTree`
- ptc_viewer: multi-run span tree layout styles
- ptc_viewer: collapse span tree groups by default with count badges
- ptc_viewer: draggable sidebar resizer and preserved scroll position
- Trace sanitize `max_map_size` limit to prevent heap overflow

**Examples**

- ALMA: evolutionary memory design for GraphWorld and ALFWorld environments
- ALMA: domain-blind `Environment` behaviour with multi-env support
- ALMA: vector store with cosine similarity and real embeddings
- ALMA: grep-based DebugAgent with ptc_viewer drill-in
- RLM recursive: `pmap_max_concurrency` tuning and LCM-inspired directions

### Changed

- Consolidated `gpt-oss` registry entries to 120B only
- Simplified planner livebook to two-role pattern, dropped reviewer
- Simplified README Calculator example to use auto-extracted signatures
- Bumped `credo` 1.7.15 → 1.7.16
- Bumped `req_llm` 1.2.0 → 1.5.1

### Fixed

- Skip structs in `KeyNormalizer.normalize_keys`
- Include `raw_response` in `turn.stop` telemetry for parse errors
- Add agent names to joke workflow livebook for better trace display

## [0.7.0] - 2026-02-12

### Breaking Changes

- Removed PTC-JSON language entirely (PTC-Lisp only)
- Removed `CapabilityRegistry` module (no proven use case yet)
- Removed redundant JSON CLI and `LispAgent` shim
- Renamed `return_retries` to `retry_turns`

### Added

**Plan System & Multi-Agent Orchestration**

- Plan system with `PlanRunner` and `PlanExecutor` for multi-agent workflows
- `MetaPlanner` with trial & error replanning and replan-on-failure
- Per-task quality gates with evidence-based verification and telemetry
- Direct agent for LLM-free task execution
- Upstream dependency result injection into task prompts
- `--plan-only` / `--plan` CLI flags and Lisp syntax validation for plans

**Journaled Task System**

- `(task "id" expr)` — idempotent journaled execution with journal-based caching
- Dynamic expressions as task IDs
- `step-done` and `task-reset` forms with plan progress tracking
- Journal preserved on error paths

**PTC-Lisp Enhancements**

- Tree traversal functions: `walk`, `prewalk`, `postwalk`, `tree-seq`
- `boolean` and `type` built-in functions
- `:when`, `:let`, `:while` modifiers for `for` and `doseq`
- Map support for `take`, `drop`, and `distinct` family
- Extended keyword chars for operator keywords (Clojure conformance)
- `index-of` and `last-index-of` string builtins

**Tracing & Observability**

- `ptc_viewer` web UI with interactive DAG graph visualization
- Gantt timeline for `pmap` parallel execution in trace viewer
- Expandable execution tree for recursive traces
- Turn pill badges and timeline overview
- Cross-process trace propagation via `TraceContext` module
- `PlanTracer` for plan-layer telemetry (phases, inputs, replan events)
- Trace result preview increased to 64KB
- `trace.stop` event with total duration on collector stop

**SubAgent Improvements**

- `thinking` option for SubAgent and demo CLI
- Configurable sandbox timeout and heap limits via application env
- Unified `builtin_tools` option (replaced `grep_tools`)
- Tool result caching and `child_steps` accumulation
- Pre-execution checks for undefined vars and unknown tools
- Prompt caching support for Anthropic, OpenRouter, and Bedrock

**Examples & Documentation**

- `page_index` example for hierarchical document retrieval with benchmarks
- `supply_watchdog` example project
- Meta Planner guide, Navigator guide, observability guide
- Plan-and-execute livebook and capability registry livebook

### Changed

- Centralized builtin tool injection into `SubAgent.effective_tools/1`
- Replaced `find_undefined_vars` with `Lisp.validate/1`
- Extracted `TraceContext` module for centralized trace propagation
- Refactored to use `Prompts` module for SubAgent loop
- Simplified `LanguageSpec` to use `Prompts` module
- Explicitly set `output: :ptc_lisp` in `PlanRunner`
- Bumped `req_llm` 1.2.0 → 1.5.1

### Fixed

- Prevented LLM thinking text from polluting message history
- Fixed XML-style `</clojure>` closers in code block parsing
- Made `grep` always-regex with BRE-to-PCRE auto-translation
- Hardened tracing reliability and removed duplicate tool telemetry
- Prevented `println`+`return` same turn conflict
- Fixed `(str x)` to convert single non-string arg to string
- Fixed false positive on `#"` check inside string literals
- Routed task failures to replan when `max_total_replans > 0`
- Prevented `TraceLog.Collector` crash when parent task is killed
- Collected child Steps on parent Step for TraceTree hierarchy
- Added named-arg usage example to tool signatures to prevent positional arg errors
- Scoped turn lookup by `span_id` to prevent cross-agent collisions in viewer
- Resolved dialyzer errors in linker and plan_executor

## [0.6.0] - 2026-01-30

### Added

**Language**

- `for` (minimal) list comprehension
- String functions: `.indexOf`, `.lastIndexOf`
- `builtin_tools` option for injecting builtin tools (e.g., `grep`, `grep-n`) instead of hardcoded builtins
- Collection functions: `extract`, `extract-int`, `pairs`, `combinations`, `mapcat`, `butlast`, `take-last`, `drop-last`, `partition-all`
- Aggregators: `sum`, `avg`, `quot`
- Reader literals: `##Inf`, `##-Inf`, `##NaN`

**SubAgent**

- `return_retries` for validation recovery with compression support
- `:self` sentinel for recursive agents
- `memory_strategy :rollback` for recoverable memory limit errors
- Budget introspection and callback for RLM patterns
- Last expression as return value on budget exhaustion
- `llm_query` builtin integrated into system prompts and tool normalization
- Auto-set `return_retries` for agents with tools during compile

**LLM-as-Tool Composition**

- `LLMTool` with `response_template` mode for typed LLM output
- Transparent tool unwrapping and input validation

**Tracing & Observability**

- `TraceLog` + `Analyzer` for structured SubAgent tracing
- Hierarchical tracing for nested SubAgents
- Chrome DevTools trace export
- HTML trace viewer
- Post-sandbox tool telemetry with span correlation

**Utilities**

- `PtcRunner.Chunker` for text chunking
- Configurable `pmap_timeout` for LLM-backed tools

### Changed

- Refactored SubAgent loop from recursive to iterative driver loop
- Extracted chaining, validation, and prompt modules into focused files

### Fixed

- Propagate `max_heap` option to Lisp.run and child agents
- Handle tool call positional args error gracefully
- Support `apply` with maps and variadic `max-by`/`min-by`

## [0.5.2] - 2026-01-23

### Added

- **Mustache Templates** - Standalone `PtcRunner.Mustache` module for template rendering (#719)
- **Unified SubAgent API** - CompiledAgent support with `then/3` for chaining (#709)
- Support `timeout` and `max_heap` options in compiled agent execution
- Allow SubAgentTools in compiled agents
- JSON reports with failure traces for demo benchmarks
- Signature naming convention documentation (underscores vs hyphens)
- Improved signature documentation and error messages (#715)

### Fixed

- Normalize hyphenated keys to underscores at tool boundary (#706)
- Enforce named args and string keys at tool boundary
- Normalize keys in `has_keys` constraint for better prompt clarity
- Return error for non-scalar Mustache variable expansion
- Use string keys for JSON mode and add `max_turns` for compile
- Allow `timeout` option in string convenience form
- Fix report filename extraction for Bedrock model IDs

## [0.5.1] - 2026-01-18

### Added

- **JSON Output Mode** - SubAgents can now return structured JSON instead of PTC-Lisp
  - Add `output:` field to SubAgent struct for declaring JSON schema
  - Add `Signature.to_json_schema/1` for JSON schema generation
  - Add `LLMClient.generate_object/4` for structured output generation
  - Add `LLMClient.callback/1` for SubAgent integration
  - Support array types and improved validation UX
- Add `re-seq` regex function to PTC-Lisp for extracting all matches
- Add debug mission display and tool call statistics with Clojure format output

### Fixed

- Convert keyword-style tool args to map in Lisp interpreter

## [0.5.0] - 2026-01-16

### Breaking Changes

- Replace `ctx/` namespace with `data/` and `tool/` namespaces for clearer separation
- Remove `tool_catalog` field from SubAgent (use `tools` directly)

### Added

**Observability & Message History (v0.5 theme)**

- Add `Turn` struct for immutable per-turn execution history with tool calls, prints, and memory snapshots
- Add `SingleUserCoalesced` compression strategy for token-efficient multi-turn conversations
- Add `compression: true` option to enable message compression in SubAgent
- Add `collect_messages: true` option to capture full conversation history
- Enhance `print_trace/2` with new options: `view: :compressed`, `messages: true`, `raw: true`, `usage: true`
- Add compression statistics to debug output
- Add prompt caching support by splitting static/dynamic sections

**New Functions**

- Add `distinct-by` for unique items by key function
- Add `re-split` for regex-based string splitting
- Add `rem` function and fix `mod` to match Clojure semantics
- Add multi-arity `map` and `partition` functions
- Add list index support to `get-in`, `assoc`, `update`, and related functions
- Add context filtering via static analysis to reduce memory pressure

**Other**

- Add configurable println truncation limit (`max_print_length` option)
- Add hidden fields filtering from LLM-visible output (fields starting with `_`)
- Add configurable sample limits and smart println for char lists
- Improve float support in PTC-Lisp

### Fixed

- Multi-arity map with variadic builtins
- Propagate `max_print_length` into closures and pcalls
- Show map field names in tool signatures for LLM
- Handle nil values in `Debug.print_trace` options
- Support builtin tuples in `fnil` for Clojure compatibility
- Show explicit "No tools available" message in prompt

## [0.4.1] - 2026-01-09

### Added

- Add `juxt` function combinator for multi-criteria operations
- Add variadic function support with rest parameters `[a & rest]`
- Add `max-key` and `min-key` for variadic comparisons
- Add IEEE 754 special values: `##Inf`, `##-Inf`, `##NaN`
- Add `float_precision` option to SubAgent (default: 2 decimal places)
- Add `context_descriptions` for automatic data inventory in prompts
- Extend `reduce` to work on maps, sets, and strings
- Add variadic `update` and `update-in` (match Clojure semantics)
- Add `java.time.LocalDate/parse` for date handling

### Fixed

- Preserve memory state on parse/analysis errors (multi-turn recovery)
- Handle `return`/`fail` correctly in threading macros (`->`, `->>`)
- Make `return`/`fail` terminate execution immediately
- Restore caller environment after closure execution
- Improve error messages with actionable suggestions

## [0.4.0] - 2026-01-06

### Added

- Add SubAgent API for high-level agent definition with type-safe signatures, auto-chaining, and resource limits
- Add Tracer system for immutable recording and visualization of agent execution
- Implement loop and recur support for iterative computation in PTC-Lisp
- Add character literals and string-as-sequence support for more flexible data handling
- Add `pcalls` for parallel execution of heterogeneous thunks
- Add `pmap` for parallel map evaluation
- Support vector paths in collection extraction functions for nested data access
- Add Clojure namespace normalization to improve LLM resilience

### Fixed

- Correct argument order for sort-by function to match Clojure semantics
- Fix update-vals argument order to match Clojure 1.11
- Update supported functions list (add frequencies, add float and for)
- Improve multi-turn agent guidance and system prompts
- Add specific error messages for predicate functions
- Fix Clojure compatibility for destructuring, count, and empty?

## [0.3.4] - 2025-12-25

### Added

- Add seqable map support to filter, remove, and sort-by operations
- Add entries and identity functions to PTC-Lisp
- Add sandbox support to PtcRunner.Lisp for resource limits

### Fixed

- Replace length() comparisons with Enum.empty? alternative
- Update error handling to use error tuples instead of raised exceptions

## [0.3.3] - 2025-12-22

### Added

- Add `update` and `update-in` map bindings for transforming values with functions
- Add function-based key support to `*-by` operations for custom sorting and grouping
- Add spec validation system for PTC-Lisp with multi-line examples and section reporting
- Improve JSON DSL prompts for better LLM accuracy

### Fixed

- Fix JSON agent to retry on empty LLM responses
- Improve deterministic ordering in keys/vals output
- Align `assoc-in` and `update-in` with Clojure semantics for intermediate path creation
- Correct `update/3` semantics to pass nil to function for missing keys
- Fix zip and into operations to return vectors instead of tuples
- Handle empty and nil LLM responses gracefully in agent loop

## [0.3.2] - 2025-12-20

### Added

- Add format_error/1 for human-readable error messages

### Fixed

- Include ptc-lisp-llm-guide.md in hex package

## [0.3.1] - 2025-12-13

### Added

- Improve PTC-JSON system prompt for better LLM accuracy
- Add object operation to construct maps with evaluated values (#253) (#254) ([#254](https://github.com/andreasronge/ptc_runner/pull/254))
- Enhance Clojure validation to execute and compare results
- Add auto-generated report filenames and reports directory
- Add cross-dataset join test case and clean up old reports
- Add --show-prompt option to display system prompts
- Add arithmetic operations (add, sub, mul, div, round, pct) #255
- Add membership operations (in, filter_in) (#257) (#259) ([#259](https://github.com/andreasronge/ptc_runner/pull/259))
- Add implicit object literals for memory storage (#256) (#261) ([#261](https://github.com/andreasronge/ptc_runner/pull/261))

### Fixed

- Handle Map values in constraint errors and fix GenServer timeout
- Correct round operation documentation for precision constraints
- Improve LLM prompt with arithmetic ops and better examples
- Evaluate filter_in value when it's a DSL expression
- Add sort_by order:desc to LLM prompt

## [0.3.0] - 2025-12-11

### Added

- Add PTC-Lisp LLM generation benchmark (Phase 1)
- Improve generation and judge prompts for PTC-Lisp benchmark
- Improve benchmark with edge cases, better judge, and dry run output
- Add autonomous issue creation and GitHub Project integration to PM workflow
- Enhance PM workflow with tech debt priority and efficiency fixes
- Auto-trigger implementation on ready-for-implementation label
- Auto-trigger code review for PRs from claude/* branches
- Install git pre-commit hook in Claude workflow
- Create PtcRunner.Json public API and deprecate PtcRunner (#103) ([#103](https://github.com/andreasronge/ptc_runner/pull/103))
- Allow full Bash access in claude.yml workflow
- Implement PTC-Lisp parser infrastructure (Phase 1) - Closes #106 (#107) ([#107](https://github.com/andreasronge/ptc_runner/pull/107))
- Implement PTC-Lisp analyzer infrastructure (Phase 2) - Closes #108 (#109) ([#109](https://github.com/andreasronge/ptc_runner/pull/109))
- Implement PTC-Lisp eval infrastructure (Phase 1) - Closes #111 (#112) ([#112](https://github.com/andreasronge/ptc_runner/pull/112))
- Implement PtcRunner.Lisp entry point with memory contract - Closes #115 (#116) ([#116](https://github.com/andreasronge/ptc_runner/pull/116))
- Add hourly schedule trigger to PM workflow
- Add pre-computed phase status to PM workflow prompt
- Implement LispGenerators module with StreamData generators (#130) (#132) ([#132](https://github.com/andreasronge/ptc_runner/pull/132))
- Add property tests for evaluation safety and determinism (#133) (#134) ([#134](https://github.com/andreasronge/ptc_runner/pull/134))
- Add domain property tests for arithmetic, collections, types, and logic (#135) (#136) ([#136](https://github.com/andreasronge/ptc_runner/pull/136))
- Support flexible key access in where clause field accessors (#137) (#138) ([#138](https://github.com/andreasronge/ptc_runner/pull/138))
- Add Lisp.Schema module and extend Runtime with flexible key access (#139) ([#139](https://github.com/andreasronge/ptc_runner/pull/139))
- Add truncation hints to guide LLM query refinement
- Add PTC-Lisp CLI and enhance demo infrastructure
- Refactor PM workflow to use Epic Issue pattern
- Add LispTestRunner and improve multi-turn support
- Add file size analysis to PR review workflow
- Add #{...} set literal syntax support (Phase 1 of #164) (#166) ([#166](https://github.com/andreasronge/ptc_runner/pull/166))
- Add {:set, [t()]} to AST type specifications (#167) (#168) ([#168](https://github.com/andreasronge/ptc_runner/pull/168))
- Add set analysis support (Phase 3 of #164) (#170) ([#170](https://github.com/andreasronge/ptc_runner/pull/170))
- Add set evaluation support (Phase 4 of #164) (#172) ([#172](https://github.com/andreasronge/ptc_runner/pull/172))
- Add .env support and model selection for e2e tests
- Add flex_fetch/2 and flex_get_in/2 to Runtime module (#188) ([#188](https://github.com/andreasronge/ptc_runner/pull/188))
- Add update-vals for map value transformation
- Create TestRunner.Base with shared constraint/formatting functions (#197) ([#197](https://github.com/andreasronge/ptc_runner/pull/197))
- Create TestRunner.Report with markdown generation (#199) ([#199](https://github.com/andreasronge/ptc_runner/pull/199))
- Create TestRunner.TestCase with shared test definitions (#201) ([#201](https://github.com/andreasronge/ptc_runner/pull/201))
- Create CLIBase with shared CLI utilities (#203) ([#203](https://github.com/andreasronge/ptc_runner/pull/203))
- Set up demo test infrastructure (MockAgent, test config) - Closes #205 (#206) ([#206](https://github.com/andreasronge/ptc_runner/pull/206))
- Create JsonTestRunner with shared modules support
- Create JsonCLI module with test mode support (#217) ([#217](https://github.com/andreasronge/ptc_runner/pull/217))
- Add memory support to JSON Agent (#220) (#221) ([#221](https://github.com/andreasronge/ptc_runner/pull/221))
- Add agent injection to test runners for MockAgent testing (#222) (#223) ([#223](https://github.com/andreasronge/ptc_runner/pull/223))
- Add ModelRegistry and unify test cases (#227) ([#227](https://github.com/andreasronge/ptc_runner/pull/227))
- Add --runs=N option for running tests multiple times
- Add keyword/string type coercion to where clause comparisons (#232) (#233) ([#233](https://github.com/andreasronge/ptc_runner/pull/233))
- Align JSON DSL memory model with Lisp (#234)
- Add take, drop, and distinct operations to JSON DSL (#236) (#243) ([#243](https://github.com/andreasronge/ptc_runner/pull/243))
- Add enhanced stats to demo test runner report (#246) (#249) ([#249](https://github.com/andreasronge/ptc_runner/pull/249))

### Fixed

- Move PM prompt to command file to fix expression length limit
- Use Bash(gh:*) pattern for PM workflow
- Trigger PM workflow on claude-approved label too
- Re-trigger code review on sync for claude/* branches
- Use --force in precommit to catch stale .beam files
- Add spec document verification to code review prompt
- Include PR comments and review comments in claude.yml
- Add mkdir permission to claude.yml workflow
- Add explicit Claude CLI install to workaround action bug
- Add safety net to push unpushed commits in PR fix workflow
- Mark PTC-Lisp implementation checklist items as complete (#123) ([#123](https://github.com/andreasronge/ptc_runner/pull/123))
- Update README with PTC-Lisp announcement and API migration guidance
- Complete API migration in Integration with LLMs section
- Implement compile-time extraction for PTC-Lisp schema prompt (#144) ([#144](https://github.com/andreasronge/ptc_runner/pull/144))
- Configure StreamData to run 300 iterations in CI (#146) ([#146](https://github.com/andreasronge/ptc_runner/pull/146))
- Make issue review always update the issue body
- Add sequential destructuring pattern type to CoreAST (#149) ([#149](https://github.com/andreasronge/ptc_runner/pull/149))
- Extend analyze_pattern for vector destructuring patterns
- Complete PR #151 - Add fn parameter destructuring documentation and tests
- Complete PR #151 - Remove stale documentation and add insufficient elements test
- Complete PR #151 - Remove stale documentation and add insufficient elements test
- Add E2E test for group-by with destructuring (#153) ([#153](https://github.com/andreasronge/ptc_runner/pull/153))
- Add analyzer unit tests for fn parameter destructuring patterns (#155) ([#155](https://github.com/andreasronge/ptc_runner/pull/155))
- Add evaluator unit tests for fn parameter destructuring patterns (#157) ([#157](https://github.com/andreasronge/ptc_runner/pull/157))
- Update LLM guide map example to use fn destructuring syntax (#159) ([#159](https://github.com/andreasronge/ptc_runner/pull/159))
- Enable sort-by with comparator and builtin HOF arguments (#160) ([#160](https://github.com/andreasronge/ptc_runner/pull/160))
- Extend multi-arity support to get and get-in (#163) ([#163](https://github.com/andreasronge/ptc_runner/pull/163))
- Unify concurrency groups for Claude issue workflows
- Add MapSet-safe collection operations and set runtime support (#175) ([#175](https://github.com/andreasronge/ptc_runner/pull/175))
- Add set literal formatting support to formatter (Phase 6 of #164) (#178) ([#178](https://github.com/andreasronge/ptc_runner/pull/178))
- Add test coverage for remove, mapv, empty?, and count on sets (#181) ([#181](https://github.com/andreasronge/ptc_runner/pull/181))
- Split eval_test.exs into multiple focused test files (#182) ([#182](https://github.com/andreasronge/ptc_runner/pull/182))
- Extract shared dummy_tool test helper (#183) (#184) ([#184](https://github.com/andreasronge/ptc_runner/pull/184))
- Support string key parameters in Lisp runtime functions (#185) ([#185](https://github.com/andreasronge/ptc_runner/pull/185))
- Standardize OpenAI model to gpt-5.1-codex-mini
- Rename duplicate module name in integration_test.exs
- Wire all call sites to use flex_fetch/flex_get_in for string/atom key interop
- Add integration tests and update docs for flexible key access (Phase 3)
- Update docs for flexible key access implementation
- Add @doc annotation to flex_get for API consistency
- Update ptc-lisp-overview.md to reflect completed flex key access (#192) ([#192](https://github.com/andreasronge/ptc_runner/pull/192))
- Update format_error references to PtcRunner.Json.format_error
- Update CHANGELOG format_error reference
- Change update-vals argument order to match Clojure 1.11
- Remove duplicate incorrect update-vals signature from LLM guide
- Handle FunctionClauseError in builtins with descriptive type errors
- Handle FunctionClauseError in multi-arity functions and complete type error messages
- Delete old TestRunner module and update README references (#219) ([#219](https://github.com/andreasronge/ptc_runner/pull/219))
- Require closing keyword in PR body for auto-close
- Add --report option to Lisp CLI Options table
- Update demo CLI to use ModelRegistry.resolve pattern (#229) ([#229](https://github.com/andreasronge/ptc_runner/pull/229))
- Update guide.md to reflect new JSON DSL API signature
- Update guide.md and demo to use new 4-tuple return format
- Handle invalid map destructuring syntax gracefully in analyzer
- Improve error message for update-vals with swapped arguments
- Update JSON agent to use new memory model API (#235) (#241) ([#241](https://github.com/andreasronge/ptc_runner/pull/241))
- Filter nil opts in CLI to allow Keyword.get defaults
- Split transformation_test.exs into access_test.exs and collection_test.exs (#244) (#247) ([#247](https://github.com/andreasronge/ptc_runner/pull/247))
- Align PTC-Lisp semantics with Clojure specification (#245) (#248) ([#248](https://github.com/andreasronge/ptc_runner/pull/248))
- Resolve remaining Clojure conformance test failures (#250) ([#250](https://github.com/andreasronge/ptc_runner/pull/250))

## [0.2.0] - 2025-12-05

### Added

- Add introspection operations (keys, typeof) to DSL (#92) ([#92](https://github.com/andreasronge/ptc_runner/pull/92))
- Improve DSL consistency for better LLM program generation (#94) ([#94](https://github.com/andreasronge/ptc_runner/pull/94))
- Add explore mode for schema discovery (#97) ([#97](https://github.com/andreasronge/ptc_runner/pull/97))
- Enable async execution for test modules (#98) ([#98](https://github.com/andreasronge/ptc_runner/pull/98))
## [0.1.0] - 2025-12-03

### Added

- Add CI check to verify STATUS.md is updated in PRs
- Implement Phase 1 core interpreter with JSON parsing and sandbox execution (#10) ([#10](https://github.com/andreasronge/ptc_runner/pull/10))
- Add pre-implementation check for blockers in PM workflow
- Implement get operation for nested path access (fixes #17) (#18) ([#18](https://github.com/andreasronge/ptc_runner/pull/18))
- Implement comparison operations (neq, gt, gte, lt, lte) (#22) ([#22](https://github.com/andreasronge/ptc_runner/pull/22))
- Implement collection operations (first, last, nth, reject) (#26) (#27) ([#27](https://github.com/andreasronge/ptc_runner/pull/27))
- Implement contains, avg, min, max operations (#28)
- Implement let variable bindings for Phase 3 (#30) (#31) ([#31](https://github.com/andreasronge/ptc_runner/pull/31))
- Implement if conditional operation for Phase 3 (#32) (#33) ([#33](https://github.com/andreasronge/ptc_runner/pull/33))
- Implement boolean logic operations (and, or, not) for Phase 3 (#34) (#35) ([#35](https://github.com/andreasronge/ptc_runner/pull/35))
- Implement combine operations (merge, concat, zip) for Phase 3 (#37) ([#37](https://github.com/andreasronge/ptc_runner/pull/37))
- Implement call operation for tool invocation (#41) ([#41](https://github.com/andreasronge/ptc_runner/pull/41))
- Add Jaro-Winkler typo suggestions for unknown operations (#44) ([#44](https://github.com/andreasronge/ptc_runner/pull/44))
- Add ExDoc and Hex package metadata (#45) (#46) ([#46](https://github.com/andreasronge/ptc_runner/pull/46))
- Implement declarative schema module for DSL operations (#52) ([#52](https://github.com/andreasronge/ptc_runner/pull/52))
- [Phase 5] JSON Schema Generation (#50) (#55) ([#55](https://github.com/andreasronge/ptc_runner/pull/55))
- [Phase 5] E2E LLM Testing Infrastructure (#51) (#57) ([#57](https://github.com/andreasronge/ptc_runner/pull/57))
- Adopt program wrapper as canonical PTC format - Update to_json_schema/0 (#63) ([#63](https://github.com/andreasronge/ptc_runner/pull/63))
- Adopt program wrapper as canonical PTC format in parser (#58) (#64) ([#64](https://github.com/andreasronge/ptc_runner/pull/64))
- Add structured output support with generate_program_structured! for E2E tests (#65) (#67) ([#67](https://github.com/andreasronge/ptc_runner/pull/67))
- Validate tool function arities at registration time (#42) (#68) ([#68](https://github.com/andreasronge/ptc_runner/pull/68))
- Add interactive demo CLI for PTC with ReqLLM integration (#75) ([#75](https://github.com/andreasronge/ptc_runner/pull/75))
- Add to_prompt/0 for token-efficient LLM text mode (#80) ([#80](https://github.com/andreasronge/ptc_runner/pull/80))
- Add security gates and hardening to Claude workflows

### Fixed

- Add safety improvements to GitHub workflows
- PM workflow commits STATUS.md directly to main
- Avoid parallel PRs by including STATUS.md in implementation PR
- Simplify STATUS.md update rules to prevent merge conflicts
- Improve PM workflow action handling
- Trigger PM workflow when issue becomes ready-for-implementation
- Ensure git push happens immediately after commit in Claude workflow
- Use PAT in issue-review workflow to trigger PM workflow
- Optimize min_list and max_list performance and update avg docs
- Correct documentation for sum vs avg behavior with non-numeric values
- Use anyOf for nested expressions in LLM schema (#71) ([#71](https://github.com/andreasronge/ptc_runner/pull/71))
- Improve LLM schema descriptions and use Haiku 4.5 (#73) ([#73](https://github.com/andreasronge/ptc_runner/pull/73))
- Store last_result in Agent state to avoid regenerating random data (#79) ([#79](https://github.com/andreasronge/ptc_runner/pull/79))
- Add test_coverage configuration to exclude test support modules (#89) ([#89](https://github.com/andreasronge/ptc_runner/pull/89))
[0.13.0]: https://github.com/andreasronge/ptc_runner/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/andreasronge/ptc_runner/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/andreasronge/ptc_runner/compare/v0.10.1...v0.11.0
[0.10.1]: https://github.com/andreasronge/ptc_runner/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/andreasronge/ptc_runner/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/andreasronge/ptc_runner/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/andreasronge/ptc_runner/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/andreasronge/ptc_runner/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/andreasronge/ptc_runner/compare/v0.5.2...v0.6.0
[0.5.2]: https://github.com/andreasronge/ptc_runner/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/andreasronge/ptc_runner/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/andreasronge/ptc_runner/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/andreasronge/ptc_runner/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/andreasronge/ptc_runner/compare/v0.3.4...v0.4.0
[0.3.4]: https://github.com/andreasronge/ptc_runner/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/andreasronge/ptc_runner/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/andreasronge/ptc_runner/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/andreasronge/ptc_runner/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/andreasronge/ptc_runner/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/andreasronge/ptc_runner/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/andreasronge/ptc_runner/releases/tag/v0.1.0
