# Stable CLI and transport-neutral application plan

**Status:** accepted; Checkpoints A–E are complete. Standalone packaging in
Checkpoint F is next, followed by final acceptance in Checkpoint G.
**Revised:** 2026-08-09 to record Checkpoint E completion and retain the
contracts that still constrain Checkpoints F–G.

This plan now describes unfinished delivery work. Implemented architecture
belongs in the [Kernel maintainer guide](../../guides/kernel-maintainer.md),
current user behavior belongs in
[Running and debugging](../../guides/running-and-debugging.md), and the checked-in
machine contract is
[`ptc-command-envelope-v1.schema.json`](../../../priv/schemas/ptc-command-envelope-v1.schema.json).
Git history retains the detailed Checkpoint A–D implementation record.

## Goal

Deliver one shared Elixir command implementation used by the existing Mix
frontend and a standalone `ptc` executable, with:

- stable, privacy-safe JSON command envelopes;
- `help`, `version`, `validate`, `run`, `doctor`, `models`, and `init`;
- filesystem and in-memory application acquisition through sealed requests;
- explicit phase ordering and a monotonic provider-activity marker;
- one owner-backed provider lifecycle for one-shot commands and manifest REPLs;
- bounded execution, cleanup, and artifact publication; and
- no application path in the execution core.

PtcRunner is a 0.x library. Remove obsolete entry points and option names
instead of adding compatibility aliases or shims.

## Delivered foundation

Checkpoints A–D delivered the foundation this plan now builds on:

- deterministic package, content, and effective-application identity;
- sealed `RunRequest`, `PreparedRun`, command arguments, diagnostics, outcomes,
  and generated command schema;
- pure preparation separated from provider activation;
- one absolute-deadline model, one provider-session owner, scoped process/port
  registration, bounded reverse-order cleanup, and caller-death handling;
- process-local OAuth, bounded credentials, provider acquisition, connectivity,
  and `doctor --connect`;
- one sealed provider-acquisition entry and one shared schema-path walker;
- one-shot execution through `ExecutionSessionOwner` with owner-created sinks;
- destination preflight through sealed publication authority; and
- ordered artifact publication with private-result recovery.

Do not reopen those designs in Checkpoint E merely to restate or generalize
them. Existing focused and repository-wide tests remain regression gates.

## Constraints for the remaining work

1. There is one argv grammar and one `CommandEngine`. Frontends may adapt
   process or Mix behavior, but may not reimplement command semantics.
2. There is one execution owner, at most one provider session, one cleanup
   stack, one provisional-root registrar, and one monotonic provider-activity
   marker per active operation.
3. Pure preparation performs no credential resolution, OAuth work, provider
   callback, optional-application startup, external process/port startup,
   network request, or artifact publication.
4. Provider-free commands open no provider session and perform no provider,
   credential, OAuth, provider-owned process/port, or network work. Bounded
   internal validation and compilation workers remain permitted.
5. Standalone V1 keeps OAuth execution disabled. The existing repeatable
   `mix ptc.run --authorize-mcp NAME` option is the only shipped interactive
   authorization path.
6. Frontends never render arbitrary Elixir terms, inspected exceptions, paths,
   credentials, selectors, private values, or raw provider responses.
7. Keep orchestration modules below roughly 500 lines. Crossing that size
   requires extracting a cohesive pure component or simplifying the state
   model. Do not add another facade over an oversized module.
8. Keep one review slice below roughly 1,500 changed lines. Split Checkpoint E
   into coherent commits when necessary.
9. Before cutting over a transitional production entry point, add an exact
   dev/production caller inventory enforced by CI/Xref. A test caller alone is
   not a reason to retain an API. Delete the inventory, entry point, option
   plumbing, and superseded tests when the final intentional caller migrates.
   Any exception must name a retained production caller and document the
   embedding contract outside `docs/plans/`.
10. Tests cover public transitions, ownership, privacy, and failure boundaries;
    they do not mirror private branches.

## Shared command contract

The accepted command surface is:

```text
ptc --help
ptc help [COMMAND]
ptc COMMAND --help
ptc --version
ptc version
ptc validate ptc.json [--host-config HOST.json]
ptc run ptc.json [--host-config HOST.json]
    [--input INPUT.json | --private-input INPUT.json]
    [--trace-dir DIR]
    [--output PATH | --private-output PATH]
    [--inspect PATH]
    [--component-override-descriptor PATH]
ptc doctor [ptc.json] [--host-config HOST.json] [--connect]
ptc models --host-config HOST.json
ptc init DIRECTORY
```

Remove `--mission`, `--private-mission`, `--trace PATH`, and `run --check`.
Do not add compatibility aliases. The REPL remains a distinct streaming
protocol and is not added to the single-envelope standalone grammar.

The Mix adapter prepends the fixed `run` command and may additionally accept
the Mix-only authorization option. The standalone wrapper alone owns exact
process streams and exits. Shared Elixir code returns a closed outcome and
never halts the VM.

### Phase order

The stable phase order remains externally observable through diagnostics and
the provider-activity field:

| Phase | Work | Provider activity allowed? |
| --- | --- | --- |
| 1 | Parse argv; handle help/version | No |
| 2 | Acquire and validate host configuration | No |
| 3 | Acquire and validate application/input | No |
| 4 | Compile bundles and resolve dependencies | No |
| 5 | Normalize selections, limits, flow, and identity | No |
| 6 | Preflight requested destinations or terminal authority | No |
| 7 | Run audited-local declaration checks | No |
| 8 | Mark activity and open the provider session | Yes |
| 9 | Execute the Kernel or active doctor operation | Yes |
| 10 | Validate and classify the result | Yes |
| 11 | Close the provider session in reverse order | Yes |
| 12 | Publish authorized artifacts and the terminal envelope | No new activity |

Once provider activity is true, it never becomes false, including on failure.
Provider-free commands skip provider phases without opening a provider session.
A provider-free run still uses `ExecutionSessionOwner` for sink ownership,
caller-death handling, cleanup, and finalization.

### Runtime and privacy boundary

`ProviderRuntimeServices` remains a sealed, path-free value supplied only when
opening active work. It contains lazy runtime activation, bounded credential
resolution, the host binding, OAuth mode, and provider-application mode. Its
construction performs no provider activity.

The Mix adapter may load `.env` only after preparation determines it is needed
and before the execution owner or operation deadline exists. Standalone V1
does not open interactive authorization. Optional applications are admitted
inside the marked session in `:command_vm` mode; a reused Mix VM may select
`:host_owned` for an already-running application.

Host-bound runtime activation retains its delivered bootstrap exception: the
operation deadline is checked immediately before and after the bounded,
code-owned activation step, but the activation itself is not hard-cancellable.
Checkpoint E must not introduce a second ownership protocol around it.

Every final command result uses the V1 envelope and the closed diagnostic
catalog. Phase-12 projection must preserve the artifact state reached by
publication. The exact wire states are `not_requested`, `not_written`,
`written`, `recovery_written`, `finalization_uncertain`, and `failed`.
`ArtifactPublisher` may separately report internal written, failed, and
withheld classifications; those classifications are not additional envelope
states. No projection publishes destination paths.

## Checkpoint E: shared commands and REPL parity

Checkpoint E finishes the shared command implementation and removes the last
frontend-owned execution path. It is a rendering, dispatch, and lifecycle
cutover, not another acquisition refactor.

**Completed 2026-08-09.** The delivered implementation:

- installs `scripts/check_stable_cli_transition.exs` in `mix precommit`; it
  scans Git's complete tracked and unignored file set across production,
  development, tests, examples, retained guides, generated artifacts, package
  inputs, and CI inputs, and freezes the expected caller set at zero for every
  E1 transitional API;
- routes `help`, `version`, `validate`, `models`, default and connected
  `doctor`, `run`, and `init` through one `CommandEngine`, with run acquisition,
  phase-6 destination authority, owner-backed execution, publication, and
  closed outcome projection split into cohesive command modules;
- reduces `mix ptc.run` to a Mix-owned startup/authorization adapter over the
  shared grammar and sealed command outcome;
- publishes the exact two-file initializer scaffold with the required
  owner-only staging and atomic no-replace commit boundary; and
- gives manifest REPLs the shared inert acquisition prefix, phase-6 privacy
  authorization, one retained provider session when required, provider-free
  operation without a host configuration, atomic owner handoff, and exactly-once
  terminal cleanup.

The cutover deleted the path-backed `RunBuilder` run helpers, transitional
phase-6/publication helpers, public `CommandEngine` request/catalog/authorize
seams, the complete internal `:check` operation, legacy run option plumbing,
and the public Mix failure/persistence test seams together with their final
callers and superseded coverage. `doctor --connect` remains independent, and a
provider-free run still uses `ExecutionSessionOwner` while omitting only the
provider session. The durable ownership, privacy, and user-facing contracts are
recorded in the Kernel maintainer and running/debugging guides.

### E1. Inventory, deletion, and module boundaries

Before changing the REPL caller:

- add the exact CI/Xref caller inventory for every remaining transitional REPL
  entry point;
- reject any dev/production caller-set growth; and
- identify the cohesive modules that keep `CommandEngine`, `mix ptc.run`, and
  `mix ptc.repl` within the maintainability budget.

The current source audit identifies the following deletion candidates. E1 must
confirm the exact caller set before editing, then delete each candidate in the
same commit as its final caller unless a retained production caller and durable
embedding contract justify it:

| Candidate | Expected cutover action |
| --- | --- |
| `RunBuilder.load_and_build/3`, `run/3`, and `run_with_class/3` | Delete the path-backed convenience APIs after the manifest REPL moves to sealed preparation. Tests and examples must migrate to the retained `build/3` or `build_prepared/3` boundary rather than preserve these APIs. |
| `RunBuilder.preflight_prepared/2` and `publish_execution/2` | Delete frontend phase-6/publication conveniences once shared dispatch owns those phases. Retain only the lower-level boundary the shared engine actually uses. |
| `CommandEngine.authorize/1` | Delete the alias in favor of the canonical `preflight/1` boundary. |
| `CommandEngine.request/3` and `catalog/1` | Make private or delete after the Mix adapter stops calling the transitional helpers; do not leave public `@doc false` test seams. |
| The complete `:check` operation route | Delete `RunCoordinator.check/*`, `RunBuilder.check_built*`, and the `:check` branches/types in `ExecutionSessionOwner`, `ProviderExecution`, `ProviderActiveSession`, and `ProviderSession` when `run --check` is removed. `doctor --connect` remains its own operation rather than an alias over this route. |
| `:mission`, `:private_mission`, and `:trace` acquisition/build option plumbing | Delete the obsolete names and validation branches with the old CLI options. Do not retain internal aliases for them. |
| `Mix.Tasks.Ptc.Run.failure_message/1` and `Mix.Tasks.Ptc.Repl.persist_terminal_result/3` | Delete or privatize these public test seams when shared outcome projection and owner finalization replace their frontend callers. |

The list is a deletion floor, not an allowlist. During each cutover, remove
newly unreachable private helpers, aliases, types, tests, fixtures, and module
documentation in the same change. Do not copy a helper into a new module before
checking whether the old helper can simply be deleted.

Good extraction boundaries include run-outcome projection, initialization,
frontend runtime setup, and manifest-REPL opening. There must still be one
public command dispatch and one execution lifecycle.

### E2. Complete shared command dispatch

Finish `help`, `version`, `validate`, `models`, `doctor`, `run`, and `init`
through one command engine:

- `help` and `version` complete during phase 1 without opening files or
  starting the command core;
- `validate` stops after inert preparation and reports provider activity false;
- `models` loads one bounded host document and projects
  `InstallationCatalog.public_installations/1` in alias order without invoking
  a local callback, resolver, store, provider application, process, port, or
  network operation;
- default `doctor` retains its audited-local-only phase-7 behavior;
- `doctor --connect` retains the delivered shared active-session boundary;
- `run` authorizes destinations, executes through `RunCoordinator`, publishes
  through the retained artifact publisher, and projects one closed classified
  command outcome; and
- `init` uses the bounded initialization state machine below.

The run projection must cover:

- normal and private success;
- setup failure before the activity marker;
- active provider, Kernel, result-guard, cleanup, and internal failure;
- usage and evaluation-memory evidence when available;
- primary/secondary diagnostic precedence; and
- every ordinary and private-recovery artifact state admitted by the checked-in
  schema.

Do not let a frontend construct envelope maps directly. Add closed constructors
or a sealed projection boundary so malformed, forged, or private-bearing
reports cannot be rendered.

The shared engine may accept a sealed frontend runtime value for VM-owned
choices such as application mode, Mix authorization targets, authorization URL
notification, and `.env` setup. It must not retain a plaintext host document or
reopen host/application paths after acquisition.

### E3. Cut over the Mix run adapter

Replace the current Mix parser, execution, publication, and result-rendering
path with a thin adapter over shared command dispatch:

- prepend `run` to the stable argv grammar;
- keep only the explicit Mix authorization extension;
- preserve the process-local OAuth context for the immediately following run;
- use the shared closed envelope for both success and failure; and
- delete the legacy parser, check presentation, raw failure-code traversal,
  result rendering, and superseded tests.

Remove the obsolete option names in the same cutover. `run --check` is replaced
by `doctor --connect`; it is not retained as a hidden or deprecated route.

### E4. Initialization

Define one minimal, domain-neutral scaffold containing exactly `main.clj` and
`ptc.json`. The exact bytes become a tested contract of the initializer.

Before touching the filesystem, render both files in memory and validate the
complete application through the same memory-package preparation boundary used
by ordinary commands. Initialization then:

1. constructs and validates the complete scaffold under a newly created,
   owner-only, invocation-private staging directory beside the target;
2. cleans only that unpublished staging directory on pre-commit failure,
   removing its two known children explicitly and leaving it untouched if its
   ownership becomes uncertain;
3. publishes the completed directory as the final fallible initialization step
   through a small platform adapter using atomic no-replace directory rename —
   `renameat2(RENAME_NOREPLACE)` on Linux and `renamex_np(RENAME_EXCL)` on
   macOS;
4. treats a successful rename as the commit point and never rolls back or
   deletes the published target, even if later frontend output fails; and
5. maps collision, symlink, unsupported-target, staging, and publication
   failures to `publication/initialization_failed` without merging with or
   deleting the requested target.

The native adapter owns only no-replace publication. It does not add an atomic
conditional-delete primitive or hostile same-user containment. A supported
target without the named no-replace primitive fails safely before publication.

Successful unpublished-staging cleanup permits a clean retry. No branch
recursively deletes the target directory, and no branch deletes it after the
publication commit point.

### E5. Manifest REPL parity

Direct and profile REPL modes keep their distinct current contracts. A
manifest-backed REPL must enter through the same preparation and active-session
prefix as a one-shot run:

- add manifest-only `--host-config HOST.json`;
- reject it in direct, profile, and profile-description modes;
- require it when a manifest selects a provider, while allowing a
  provider-free manifest to omit it;
- acquire the same inert catalog and sealed runtime services as `mix ptc.run`;
- authorize the REPL trace/terminal destination in phase 6;
- run the shared phase-7 checks before the activity marker;
- open and acquire one provider session for the entire REPL lifetime; and
- atomically transfer the execution-owner handle, sinks, run state, and active
  provider lifecycle to `ReplSessionOwner` before returning the session.

Repeated evaluations reuse that one session. Normal close, abort, caller death,
worker death, and deadline failure all use the same bounded cleanup and finalize
the sinks exactly once. The frontend has no parallel sink- or provider-cleanup
path.

The retained `TraceLog.append_jsonl/3` admin primitive is not transitional.
Checkpoint E may keep or replace the REPL's current use of it, but whichever
path remains must preflight before provider activity and preserve private trace
permissions and terminal cleanup ordering.

After classification and during phase 6, a private manifest REPL requires both
an explicit `--private-terminal` authorization and attached stdin/stdout
terminals. It rejects detached, load, eval, script, stdin, and JSONL modes before
phase 7 or execution-owner opening. Rejection must prove provider activity
false and zero callback, credential, OAuth, application, process, port, and
network work.

### Checkpoint E gate

Checkpoint E is complete when:

- Mix and direct/shared fixtures produce the same safe outcomes, ignoring only
  independently generated command references where appropriate;
- help, version, validate, models, and default doctor perform zero provider
  activity;
- `models` has a hostile callback sentinel proving it is declaration-only;
- provider-free and provider-backed runs produce schema-valid classified
  envelopes across execution, cleanup, and publication failures;
- obsolete run options and the old `--check` path are absent, including the
  internal `:check` operation branches and types rather than only the parser;
- `init` collision, symlink, partial-write, staging-ownership replacement,
  pre-commit rollback, publication-commit, post-commit frontend-failure, and
  clean-retry tests pass without target deletion;
- a provider-backed manifest REPL obtains the same trusted installation as
  `mix ptc.run`, acquires once, reuses one command-VM session, and closes once;
- a provider-free manifest REPL works without host configuration;
- every private manifest REPL rejection occurs before phase 7 and active work;
- each migrated transitional entry point, its inventory, and superseded tests
  are deleted together;
- Xref/static deletion gates prove the E1 candidates have no stale production
  callers, aliases, option names, or documentation; and
- affected module docs and implemented guides no longer describe the removed
  paths.

## Checkpoint F: standalone packaging

Checkpoint F packages the shared command implementation without changing its
grammar or semantics.

### F1. Release entrypoint and outer wrapper

Add:

- the release entrypoint that invokes shared command dispatch;
- launcher framing between the wrapper and the command writer; and
- a small native outer wrapper that owns caller stdout and stderr before BEAM
  starts.

The existing MCP stdio launcher is a different protocol and must not be reused
as the standalone command wrapper.

The exact durable process contract is retained in
[Running and debugging](../../guides/running-and-debugging.md#stable-standalone-process-contract).
In summary, the wrapper alone publishes one bounded envelope to stdout, keeps
VM/provider stderr behind a code-owned boundary, maps closed outcomes to their
documented exit status, and handles framing failure through the retained
transport-failure behavior.

The fresh standalone VM uses command-owned optional-application mode and
disables interactive OAuth. Help and version must still complete without
starting the command core or reading configuration.

### F2. Descriptor, stderr, and signal evidence

Packaged conformance tests cover:

- stdin and argv framing;
- exactly one ordinary-path JSON envelope on stdout;
- documented success, classified-failure, internal-failure, and
  framing-failure statuses;
- broken caller stdout;
- descriptor inheritance and child process/port behavior;
- startup identity and optional console handlers; and
- the retained V1 signal non-guarantees.

Sentinels cover `IO.warn`, `:standard_error`, Logger/SASL, optional console
handlers, child stderr, and known NIF/native direct-descriptor routes. Any
reachable route that can render caller/provider material must be removed or
captured behind the wrapper. Child processes and ports must not inherit the
private envelope descriptor.

Signal tests characterize supported-target behavior without promoting an
observed signal exit status or cleanup sequence into the V1 contract. If a
supported target cannot preserve the stream/descriptor contract, or a real
deployment requires bounded application bootstrap or reliable signal cleanup,
start the separately triggered outer-supervisor design.

### Checkpoint F gate

Checkpoint F is complete when the packaged conformance suite passes on every
supported target and proves the retained stdout, stderr, descriptor, exit, and
startup contracts without weakening the V1 signal non-guarantees.

## Checkpoint G: acceptance and documentation

Checkpoint G reconciles the implementation with retained documentation and
runs the complete acceptance matrix:

- update CLI, host-configuration, Kernel-maintainer, OAuth, REPL, and packaging
  documentation;
- remove this plan's now-delivered implementation detail or delete the plan if
  no approved work remains;
- run memory-vs-directory, provider-free, MCP OAuth, live-model, filesystem,
  REPL, and packaged acceptance matrices;
- regenerate schemas, semantic projections, and generated references; and
- complete one clean cumulative independent review against the latest
  `origin/main`.

**Gate:** `mix precommit`, `MIX_ENV=dev mix docs --warnings-as-errors`, packaged
conformance, and every configured credentialed acceptance run pass on the exact
reviewed tree.

## Delivery and review protocol

Use one PR per checkpoint, each based on the updated `origin/main` after its
predecessor merges. Checkpoint E may contain several coherent commits to stay
within the review budget, but it remains one value-bearing PR.

Before every commit:

1. write the observable boundary, production caller cutover, ownership/failure
   matrix, privacy boundary, and deleted transitional path;
2. add a failing integration test before a bug fix or lifecycle change;
3. format, compile with warnings as errors, and run focused tests;
4. regenerate affected artifacts;
5. run the required incremental independent review and resolve its findings;
6. run `mix precommit`; and
7. run `MIX_ENV=dev mix docs --warnings-as-errors` when documentation changes.

At the checkpoint boundary, fetch and reconcile `origin/main`, rerun the full
gates, and perform one fresh cumulative review. Do not cold-review
byte-identical trees more than once.

## Final acceptance properties

The completed E–G branch must demonstrate:

- one shared parser and command semantic implementation for Mix and standalone,
  except for the explicit Mix-only authorization option;
- memory and directory packages produce identical identities and behavior;
- provider-free commands perform no provider, credential, OAuth,
  provider-owned process/port, or network work;
- provider activity changes only from false to true at the active boundary;
- a manifest REPL uses one provider session for its lifetime and shares the
  one-shot cleanup and caller-death guarantees;
- private manifest REPL values reach only an attached, explicitly authorized
  terminal and never detached, scripted, stdin, eval, load, or JSONL output;
- public envelopes contain no private data, path, credential, arbitrary term,
  selector, or raw provider response;
- private results cannot succeed without an authorized owner-only sink;
- provider cleanup precedes final result publication;
- `init` never merges with, overwrites, recursively deletes, or removes a
  concurrently replaced filesystem entry;
- standalone streams, descriptors, exit behavior, and startup identity conform
  on every supported target while signals retain their explicit non-guarantee;
  and
- generated schemas, semantic projections, module docs, and retained guides
  agree with the implementation.

## Explicit deferrals

The following remain out of scope until a concrete adapter or deployment
requires them:

- remote OAuth stores, cross-clock deadline translation, replay catalogs, and
  store-local identity;
- durable cleanup journals, restart reconstruction, and exact restoration of
  prior OTP application-controller state;
- multiple OAuth context groups inside one command;
- an HTTP service, job queue, scheduling, tenant isolation, or service quotas;
- a general transactional artifact store;
- standalone durable or interactive OAuth authorization;
- a two-phase, hard-cancellable host-runtime activation protocol;
- a new LLM adapter or removal of `req_llm`/`llm_db`;
- a second general HTTP stack;
- hostile same-user or same-VM containment;
- portable signal cleanup guarantees; and
- backward-compatible CLI aliases.

Use the [durable OAuth store plan](../future/mcp-oauth-durable-store.md) only
when a real durable adapter is chosen. Define hosted-service and outer-supervisor
security at the boundary where those deployments actually exist.

## Completion criterion

This plan is complete when Checkpoints E, F, and G are delivered, all replaced
frontend and REPL paths are absent, every checkpoint has a clean exact-tree
review, repository and packaged gates pass after the final rebase, and retained
documentation describes the shipped command rather than this plan.
