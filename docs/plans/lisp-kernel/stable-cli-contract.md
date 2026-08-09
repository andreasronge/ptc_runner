# Stable CLI and transport-neutral application plan

**Status:** accepted; Checkpoints A–E are complete. The standalone command
release is next in Checkpoint F, followed by macOS and container distribution
in Checkpoint G and final acceptance in Checkpoint H.
**Revised:** 2026-08-09 to record Checkpoint E completion, replace the native
stdout-owning wrapper with a caller-named envelope destination, add the
standalone REPL that the accepted grammar never covered, and split
distribution into its own checkpoint.

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
protocol and is never dispatched through the single-envelope command path,
though Checkpoint F does make it a subcommand of the same executable, parsed by
the same parser. See F3.

The Mix adapter prepends the fixed `run` command and may additionally accept
the Mix-only authorization option. The release entrypoint alone turns a sealed
outcome status into a process exit. Shared Elixir code returns a closed outcome
and never halts the VM.

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

## Checkpoint F: standalone command release

Checkpoint F makes every shared command reachable outside a source checkout. It
changes the transport of the command envelope and extends the accepted grammar
with the interactive command, but it changes no command semantics.

### F0. Superseded approach

The accepted plan previously required a native outer wrapper that owned caller
stdout and stderr before BEAM starts, redirected the VM's descriptor 1 to the
null device, and copied one framed envelope from a private descriptor. That
design existed for one reason: to promise a byte-pure machine channel on stdout
against VM, Logger, dependency, child, and NIF write routes.

Checkpoint E made a cheaper answer available. `CommandEngine.dispatch/2` now
yields `{:ok | :error, CommandOutcome.t()}`, a sealed value that already carries
its `exit_status`, so the envelope no longer has to be produced by writing to a
stream at all.

State the reason precisely, because the obvious phrasing is wrong. Dispatch is
**not** transitively stream-pure: the core modules render no stream, but
dispatch invokes runtime callbacks, the Mix authorization notifier writes
through `Mix.shell`, and starting an optional provider application may install
handlers or emit output. A process-wide purity claim would not survive review.

The wrapper is unnecessary because the envelope stops being a stream artifact.
Written to a caller-named file through the retained atomic publication
boundary, it cannot be interleaved with anything, whatever else the VM, its
dependencies, or its children write — and stdout is demoted to best-effort
human output whose contamination no longer matters. That is a property of the
destination, not of the code's discipline, which is why it holds without
descriptor interception.

The wrapper, the launcher framing protocol, the private envelope pipe, the
broken-caller-stdout path, the descriptor-inheritance obligations, and the
`IO.warn`/`:standard_error`/Logger/SASL/child-stderr/NIF sentinel matrix are
withdrawn with this revision. What survives is the envelope schema, the exit
status vocabulary, the privacy rules, and the signal non-guarantees.

Do not reintroduce a wrapper to make piped stdout authoritative. If a consumer
later requires that guarantee, add it as its own triggered design with its own
justification.

### F1. Release entrypoint and standalone runtime

Add:

- a `releases:` configuration that builds the command with the runtime
  included, so a target machine needs no Erlang or Elixir installation;
- a standalone command runtime that mirrors the Mix runtime's concerns —
  application start and provider-application mode — without depending on Mix at
  run time; and
- a release entrypoint that drives the two-step entry defined in F2 — generate
  the run reference, parse, validate destination distinctness, then bootstrap
  and dispatch the already-parsed request — builds the runtime, renders through
  `CommandOutcome.to_map/1`, and exits with `outcome.exit_status`.

Do not implement the entrypoint as "read argv and call
`CommandEngine.dispatch/2`". That shape is what F2 replaces: dispatch parses
internally and generates its own reference, so a frontend built that way cannot
know the envelope destination, cannot render a reference on a rejected parse,
and cannot validate destinations before bootstrap.

`CommandRuntime.standalone/0` already encodes the required VM policy:
command-owned optional-application mode, no authorization targets, and no
interactive OAuth notifier. The entrypoint uses it rather than defining a
second policy.

The standalone command performs no implicit dotenv loading. A credential
reaches it only through the host document's declared environment, file, or
literal binding. Mix keeps its own dotenv convenience because a source checkout
is a different trust context; the release must not inherit it.

`help` and `version` must continue to complete in phase 1 without starting the
command core or reading configuration, and the release must prove it rather
than inherit it.

The entrypoint owns the only `System.halt/1` in the delivered surface. Shared
modules keep their existing prohibition.

### F2. Envelope destination

Add `--envelope PATH`, naming where the command envelope is written. It must
not reuse `--output`, which already names the run's result artifact, or
`--private-output`. Fix the name here so the parser, the help topics, the
schema, and the guide cannot drift apart.

Its scope is per-command and must be settled in the declarations, not left to
inference:

| Command | `--envelope` | Why |
| --- | --- | --- |
| `run`, `validate`, `doctor`, `models`, `init` | accepted | each returns a terminal outcome a caller may want to read |
| `repl` | rejected | produces no command envelope at any point |
| `help`, `version` | rejected | they complete in phase 1 without touching the filesystem, and accepting a destination would require publishing a file — surrendering the guarantee for no benefit, since their output is the thing a human is already reading |

With the switch, the command writes exactly one V1 JSON envelope to the named
path through the retained artifact publication boundary — owner-only staging,
atomic no-replace commit — and exits with the outcome status. That file is the
machine-readable contract.

The switch names a file and only a file. It does not accept `-` or any other
stdout spelling. Stdout cannot carry owner-only staging, an atomic no-replace
commit, or an existing-entry check, so admitting it would mean two destination
contracts wearing one switch name, with partial-write and broken-pipe behavior
that the withdrawn transport-failure path used to own. A caller that wants the
envelope in a pipeline writes a file and reads it; that is one extra line and
keeps one contract.

**Delivery begins at a successful parse.** `--envelope` is an ordinary declared
option with no special extraction. Once argv parses, every later failure —
including a recoverable startup or bootstrap failure — delivers its envelope to
the named destination. Before a successful parse there is no envelope: the
command exits `2`, the arguments phase's status, and writes one closed stderr
line.

A parse is successful only once the argument *values* are validated, which
includes the resolved destination-distinctness check described below. That check
needs the filesystem, so it is not part of `CommandParser`, but it is part of
deciding whether the arguments were acceptable — and it therefore falls on the
no-envelope side of this boundary.

That ordering does not hold today and F must establish it. `MixRunAdapter`
bootstraps before it touches argv, `CommandEngine.run_startup_failure/0` takes
neither a parsed command nor a destination and always builds a `run` failure,
and `dispatch/2` parses internally, so no frontend ever learns where the
envelope should go.

Split the entry into two steps and give the frontend the result of the first:

1. generate the run reference, then parse argv once. The entry returns the
   reference on **both** outcomes — alongside the parsed request on success, and
   alongside the rejection on failure — with the envelope destination present
   only on success;
2. bootstrap, then dispatch that already-parsed request, which reuses the
   reference rather than generating another.

Reference ownership has to move for this to work. `CommandParser` returns no
reference and `CommandEngine.dispatch/2` currently generates one internally, so
neither can supply one to a rejected parse — yet every failure rendering must
carry it. Generating it once in the new entry, before the parse, is what makes
"every failure carries the run reference" true rather than aspirational.

Generation can fail. `CommandRunRef.generate/0` returns
`{:error, :entropy_unavailable}`, and dispatch today substitutes a fixed
fallback reference rather than failing the command. The entry preserves that
behavior and inherits its one exception: on the fallback path the reference is
no longer unique, so it identifies the command's own artifacts but cannot
distinguish concurrent commands. Say so where the reference is documented rather
than letting "every outcome carries a unique reference" read as unconditional.

The frontend then holds the destination before anything can fail recoverably,
and startup failure becomes a projection of the parsed command rather than a
hardcoded `run`. The destination travels beside the sealed outcome, never inside
it: envelopes carry no filesystem path, and that rule is unchanged.

An earlier revision tried to honor `--envelope` for rejected argv through a
pre-scan. Do not restore it. Delivery would have had to know which command was
named, since `repl` produces no envelope, so the pre-scan was a second parser
under another name. It also forced the closed schema to model "I could not read
what you asked", which has no honest `command` value. Exit status already gives
a scripted caller the discrimination it needs, because status `2` belongs
exclusively to the arguments phase: `2` means the invocation is wrong, and every
runtime-variable failure a caller would dispatch on — credential, connectivity,
destination, workflow, retryability — parses fine and lands a full envelope.
Every consumer must already handle a missing envelope for VM abort and the `74`
path, so this widens an existing branch rather than adding one.

The parse-failure path keeps F3's rejection quality. It renders the closed
phase, code, and message, and it still names an unknown switch alongside the
accepted list and a retired switch alongside its replacement. The migration
experience lives on exactly this path and must not degrade to a bare parser
error because the envelope went away.

The envelope destination must not collide with another destination, and two
earlier attempts at this rule failed the same way. A parse-time string
comparison cannot see that `out.json` and `./out.json` are one file, or resolve
a symlinked parent. Phase 6 can, but only `run` reaches it and only after host,
application, and bundle work — so a run failing earlier would already have
delivered its envelope to an unexamined path.

**The check belongs in the entry, resolved, before anything can be delivered.**
Step 1 resolves the envelope path and every artifact destination the command
could write and compares them under the artifact rule — resolved parent identity
against a case-folded basename — rejecting a collision before bootstrap and
before dispatch. That is the only moment both after the paths are known and
before any failure can be reported to one of them.

**Compare against the derivable superset, not the declared paths.** Some targets
are derived rather than declared, and the entry cannot know which will be
chosen: a trace stem yields `<run_ref>.jsonl` or `<run_ref>.private.jsonl`
depending on a privacy classification that preparation establishes later, and a
private result additionally implies its `<run_ref>`-derived recovery file. The
entry does know the run reference, because it now generates it, so every one of
those names is derivable there even though the choice between them is not. Check
the envelope against all of them. A superset comparison can only reject an
envelope path the run might have used, which is the correct bias, and it is what
keeps phase 6 envelope-blind without leaving an alias unexamined.

**A collision is an `:arguments` diagnostic, not a `destination` one.** Nothing
failed to open or publish; a combination of argument values was refused, and
resolving the paths is merely how the combination is judged. Calling it a
`destination` failure would need a phase-order exception — `destination` comes
after host, application, and bundle — and would need `init`, `validate`,
`doctor`, and `models` to start admitting destination diagnostics their outcome
contract rejects today. Neither is necessary.

Treating it as an argument failure settles three things at once. It carries exit
status `2`, already exclusive to the arguments phase. It needs no phase-order
exception, because arguments genuinely precede everything. And it lands **before
the delivery boundary**: destination distinctness is argument validation that
happens to require the filesystem, so a parse is not successful until it passes,
and a collision therefore produces no envelope, exits `2`, and writes one closed
stderr line. That line uses `conflicting_arguments` and names only the
declaration-owned switches whose destinations collide; it never includes either
caller-owned path. Init containment instead states that `--envelope` must be
outside the init directory, again without retaining either path. An unusable
envelope destination is a separate rejection that names only `--envelope`.

That last point is what makes the rule implementable. `init --envelope
TARGET/inside.json` names an envelope beneath a target directory that does not
exist yet — correctly, since `init` is about to create it. Had a collision owed
an envelope, the command would have to write one into a directory it just
refused to create, and would fall to `74` with no envelope at all, contradicting
its own delivery promise. As an argument rejection there is nothing to deliver
and no contradiction.

The parser stays filesystem-free; the entry does not, and the split is the
point. `CommandParser` declares and validates syntax; the entry resolves and
preflights the destination it is about to write to.

One check, not two. Because the entry establishes resolved distinctness between
the envelope and the artifact destinations, phase 6 keeps exactly the artifact
responsibilities it has today and gains no envelope awareness.

Two commands declare destinations. `run` accepts result, private result, trace,
and inspection paths — the trace filename derives from the run reference, which
the entry generates before parsing, so it is resolvable there. `init` declares a
positional target directory published atomically without replacement; its
envelope may be neither that target nor a path beneath it, and containment is
judged on resolved paths for the same reason equality is. `repl` declares trace
destinations but rejects `--envelope`. No other command declares a destination.

The envelope needs non-collision, not a reservation, which is why
`PublicationAuthority` never holds it: that authority closes before dispatch
returns, while the envelope bytes exist only after the terminal outcome. The
residual is the one every publication path already carries and
documents: preflight decides what is decidable up front, and each write still
closes its own races. A destination that becomes aliased after preflight fails
at commit with `74`, and the atomic no-replace commit is what makes that failure
safe rather than destructive.

Without the switch, the command does **not** write the envelope. With or without
the switch, it writes a short human rendering of the same sealed outcome. The
switch adds atomic envelope publication; it does not replace the terminal
rendering. An envelope is machine output; a person at a terminal reading a
wrapped several-hundred-character JSON line to find one message is a worse
experience than the message alone.

The rendering must carry what the invocation was for:

- a failed command renders the primary phase, code, and catalog message on one
  line, to stderr;
- a successful `run` whose result class is normal renders the result value, to
  stdout. This is the tutorial's first-touch experience and the ordinary reason
  to invoke the command; a success line that omits the value makes the value
  unreachable without also naming an artifact destination. The normal envelope
  already carries `value`, so this publishes nothing the envelope would not;
- a successful `run` whose result class is private renders only its completion
  and artifact class, never the value. The private envelope already omits the
  value, and a private result still requires an authorized owner-only sink; and
- every other successful command renders its own public projection. Help uses
  usage lines and aligned option descriptions, version prints its bare version,
  and init names the fixed files it created. The remaining structured
  projections use compact JSON.

The rendering is projected from the sealed outcome, never assembled separately,
and obeys the same privacy rules as the envelope: no private value, credential,
filesystem path, selector, arbitrary term, or inspected exception. It is
presentation, not a second contract, and callers must not parse it.

**The Mix frontend adopts this rendering in Checkpoint F, not later.** Mix is
the only frontend users have until the release ships, and it currently prints
the compact envelope on stdout and raises the raw envelope as its error message.
Leaving that in place through F and G would keep the regression in front of
every user for the whole packaging effort while the fix sits in an unshipped
binary. One shared parser and command semantics, which final acceptance already
requires, means one shared rendering: `--envelope PATH` behaves identically
under Mix, and the Mix run command renders the same human line by default. That
command is `mix ptc.run` until the generic task lands and `mix ptc run`
afterwards; the rendering is the same either way.

Rendering is a byte contract, not an intention, so fix it with fixtures rather
than adjectives. **Every rendered workflow result value is compact JSON**,
including a string result value, which therefore appears quoted and escaped.
Code-owned projections may instead use readable text because no
caller-controlled byte reaches them. Each rendering ends with exactly one
newline, the only unescaped
one it contains except for the deliberate line structure of help.

"Compact JSON" alone is not byte-exact, because it does not fix the order of
object members. Specify a deterministic encoding — a stable key order applied by
the renderer — or byte-exactness is unachievable for any value containing a map
and the fixtures cannot be written. This is a rendering concern only; the
envelope has its own schema and is unaffected.

Rendering strings raw was the wrong instinct. Unquoted output would have to
define escapes for every character that can end or hijack a line, and a public
result string can contain `ESC`, so raw rendering is a terminal-injection route
into whatever reads the output. JSON already escapes the control range under a
specification nobody has to re-derive, and it makes byte-exactness free. The
small cost is a pair of quotes around a string result.

Pin the exact fixture rows. The matrix is:

- **success, one row per rendered projection** — `run` normal, `run` private,
  `validate`, `doctor` default, `doctor --connect`, `models`, `init`, root
  `help`, per-command `help`, and `version`. Enumerate them, because "each
  non-run command" hides the two `doctor` modes and the two `help` shapes,
  which render differently;
- **failure, one row per `DiagnosticCatalog` phase**, taking the list from the
  catalog rather than restating it. It defines thirteen (`:arguments`, `:host`,
  `:application`, `:bundle`, `:provider_declaration`, `:destination`,
  `:local_preflight`, `:active_preflight`, `:provider_acquisition`,
  `:execution`, `:result_cleanup`, `:publication`, `:internal`), so any
  hand-written grouping into fewer "classes" would omit real phases and drift
  as the catalog changes;
- **five additional `:arguments` rows, supplementing rather than replacing that
  phase's row** — the unknown-switch rejection carrying its accepted list, the
  retired-switch rejection carrying its replacement, the invalid envelope
  destination naming its declaration-owned switch, the envelope collision
  carrying two declaration-owned switch names, and init containment carrying
  fixed guidance. All are `:arguments` diagnostics; they are listed separately
  because they render structure no other diagnostic does, not because they sit
  outside the catalog;
- **one row for the `74` destination failure**, the only rendered outcome that
  is not a catalog diagnostic;
- **one value-shape row**: a string result containing newlines, proving the
  compact-JSON rule collapses it to a single line; and
- **combination rows, not just outcomes.** The matrix above enumerates results;
  it would not catch a flag combination that reintroduces an interactive path
  under a machine-readable output flag. That hole is not hypothetical: the
  profile REPL's second private destination shipped a first cut admitting an
  interactive input mode alongside the non-interactive ones, so requesting JSONL
  output with no expression, script, or stdin fell through to the prompt loop
  and interleaved a human banner with JSONL records. An independent review
  caught it, not testing. Cover, for every command that has them, the input-mode
  by output-format by destination-switch combinations that must refuse rather
  than degrade — in particular that no combination selecting machine-readable
  output can reach an interactive loop. Include the rejections that are argument
  failures rather than outcomes: `--envelope` supplied to `help`, `version`, or
  `repl`, and a colliding envelope destination.

Include the run reference on the failure line. It is public, present and
validated on every outcome — every `CommandOutcome` constructor takes a
`run_ref` and enforces `CommandRunRef.valid?/1` — and the failed-run diagnosis
guidance sends a reader to find `<run_ref>.jsonl`. Without it on stderr, a
caller who requested a trace but no envelope cannot name the file the guide
tells them to open.

Failure to open, stage, or commit the envelope destination cannot be reported
through the envelope. The command writes a bounded, fixed, code-owned
diagnostic to stderr and exits `74`, the status the withdrawn transport-failure
path already reserved. No valid envelope is promised on that path.

Nothing before a successful parse, and no VM abort, produces an envelope; the
status is whatever the arguments phase or the operating system yields.
`MixRunAdapter`'s guarded bootstrap and `CommandEngine.run_startup_failure/0`
establish the shape for the recoverable post-parse part.

The durable form of this contract is retained in
[Running and debugging](../../guides/running-and-debugging.md#stable-standalone-process-contract),
which this revision rewrites alongside the plan.

### F3. The standalone interactive command

The accepted grammar covers `init`, `validate`, `run`, `doctor`, and `models`.
It has never covered the REPL, which exists only as a Mix task. A release built
from the current grammar therefore cannot serve the interactive use case at
all, and six of the seven engine commands have no frontend today.

Checkpoint F closes both gaps — but the REPL does not join the dispatch path.
`CommandEngine.dispatch/2` returns exactly one terminal `CommandOutcome` with
one exit status, and that one-shot shape is precisely what Checkpoint E bought.
A REPL is a live session with per-form results, meta-commands, and interactive
privacy authority. Giving the engine a streaming result type beside
`CommandOutcome` would fork the envelope schema and the exit-status vocabulary
to accommodate the single command that does not fit.

Checkpoint E already built the correct seam: `ManifestRepl.open/3` shares the
inert acquisition prefix, phase-6 privacy authorization, and provider-session
opening with a one-shot run, then hands off to `ReplSessionOwner`. Share the
preparation pipeline, not the dispatch loop.

So:

- add `repl` as a subcommand of the same executable with its own help topic,
  carrying the manifest and profile argument shapes the Mix task already
  accepts;
- **parse it with the same parser.** Routing diverges only after parsing:
  `repl` goes to the extracted session frontend, every other command goes
  through `CommandEngine.dispatch/2`. Its switches are enumerated by the same
  help-from-the-parser-declaration mechanism, and unknown or retired switches
  are rejected by the same closed vocabulary. A second argv convention for the
  REPL would reproduce the discoverability gap this checkpoint exists to close;
- **make option declarations per-command, because one global table cannot hold
  the REPL.** `CommandParser` today declares one switch set, rejects any
  repeated known option, and flattens results with `Map.new/1`, while the REPL
  needs ordered and repeatable `--eval` and `--resource`, short aliases, and a
  positional script argument. Each command therefore declares its own accepted
  switches, its own repeatability and ordering policy, and its own positional
  shape, and `CommandArguments` gains a representation that can carry an ordered
  repeated option list. This is what "the same parser" has to mean; without it
  the guardrail is unimplementable;
- **make the retired-switch table per-command too.** `--trace` is retired for
  `run`, replaced by `--trace-dir`, but remains a live declared option for
  `repl`. A global retirement claim is simply false, and a per-command table
  makes the rejection more precise rather than less closed: it can say a switch
  is retired for this command and name its replacement;
- `--envelope` does not apply to `repl`, which produces no command envelope at
  any point, including startup and termination. This needs no special rule:
  `repl`'s declaration does not accept the switch, so the combination is an
  ordinary closed rejection;
- extract the terminal frontend — the interactive loop, meta-commands, and
  rendering — out of the Mix task into a module the release entrypoint and the
  Mix task both drive, leaving the Mix task a thin adapter in the shape
  `mix ptc.run` now has. **Do not extract or re-derive the private-destination
  authorization.** It already lives outside the Mix task, in
  `AnalysisProfileRegistry.authorize_frontend/2` and
  `AnalysisSessionBuilder`'s private-profile validation, both written to serve
  an embedding host as well; the Mix task only parses the flags and maps error
  codes to messages. The extraction re-wires those same calls from the new
  shared module and the per-command declaration lists whichever destination
  switches exist when F lands; and
- expose every remaining engine command through release argv **and through
  Mix**. Release argv alone leaves a source-checkout user unable to run `init`,
  `doctor`, or `models` at all — which is why `getting-started.md` and
  `host-configuration.md` currently instruct them to call
  `CommandEngine.dispatch/1` inside `iex`, an instruction that survives F unless
  this is fixed. Add one generic `mix ptc <command> …` task that hands argv to
  the shared parser and renders through F2, rather than one Mix task per
  command: a single thin adapter gives full grammar parity, and it puts
  `mix ptc.run` on a path to deletion instead of leaving two spellings of the
  same command. Retiring the `iex`-dispatch instructions from the guides is part
  of this work, not a later cleanup.

  Deleting `mix ptc.run` requires somewhere for `--authorize-mcp` to live. Today
  only that hardcoded adapter extracts it, and a task that hands argv straight
  to the shared parser would reject it — which would remove the only interactive
  OAuth authorization route while the plan keeps authorization Mix-only. The
  per-command declarations introduced above are the place for it: declare
  `--authorize-mcp` on `run` as a frontend-scoped option, accepted when the
  frontend is Mix and rejected as undeclared otherwise, with its own help entry
  and rejection coverage.

  With that declared, `mix ptc run --authorize-mcp` covers everything
  `mix ptc.run` did, and **Checkpoint F deletes `mix ptc.run` in the same
  commit that lands the generic task**. Leaving both would contradict this
  plan's completion criterion, which requires replaced frontend paths to be
  absent, and would leave two spellings of one command — the outcome the
  generic task exists to avoid. Update the guides' command tables with it.

Help must document the command it describes. Today `--help` renders a usage
line that ends in `[OPTIONS]` and never enumerates them, and no help topic,
module doc, or command output lists what `--input`, `--trace-dir`, or `--output`
do. Each command's help topic must enumerate its accepted switches with a
one-line description, from the same parser declaration that accepts them, so
the two cannot drift. A retained guide table is not a substitute for a command
that can describe itself.

Rejecting an argument must also name what was wrong without echoing caller
input. The parser holds the accepted switch set, so an unknown switch reports
that it was unknown alongside the closed accepted list, and a switch retired by
this plan — `--mission`, `--private-mission`, `--trace`, and `run --check` —
reports its retirement and replacement from a fixed table. Both stay inside a
closed vocabulary; neither renders caller-supplied text.

Session ownership constrains the extraction. A REPL session is owned by the
process that calls `ReplSession.new/1` or `ManifestRepl.open/3`, the binding is
permanent, and it is enforced twice — a private ETS table in the creating
process and a caller match in `ReplSessionOwner`. The extracted frontend must
therefore run the open call and every evaluation in one long-lived process, and
must not assume it can hand a live session to another process.

Private manifest REPL values require an explicitly authorized destination, and
today the only one is an attached terminal. **Do not gate F on proving that
terminal detection discriminates correctly, because it does not.** Under
`script -q /dev/null` a non-interactive shell reports both streams as
terminals and the private path opens anyway, and a same-uid caller can read the
artifact directly regardless. The check is accident prevention — it stops a
private value reaching a log or transcript by mistake — not access control, and
the plan must not restate it as a guarantee.

What F owes is behavioral parity, which is checkable: a packaged invocation with
no attached terminal must reject the private manifest REPL before phase 7,
exactly as the Mix path does. That is a real gate. "Terminal detection is
reliable in a container" is not.

A second authorized destination shipped for the profile REPL, having established
the above: `--private-unattended` alongside `--private-terminal`, with exactly
one permitted. Checkpoint E's private-manifest gate uses the same mechanism with
no unattended equivalent, which is a recorded follow-up rather than an open
question. That is a different data class and a deliberately separate decision;
F should not invent an answer, but the frontend extraction must be shaped so a
further destination can be added without re-plumbing it, and `repl`'s
per-command declaration carries both shipped switches and their
mutual-exclusion rule.

### Checkpoint F gate

Checkpoint F is complete when:

- a release built with the runtime included runs every grammar command,
  including the interactive one, on a machine with no Erlang or Elixir
  installation;
- the envelope destination produces exactly one schema-valid envelope, commits
  atomically without replacing an existing entry, and reports its own failure
  as a bounded stderr diagnostic with status `74`;
- a recoverable startup failure delivers its envelope to the named destination,
  and an argv rejection delivers none and exits `2` with a closed stderr line
  that still names an unknown switch's accepted list and a retired switch's
  replacement;
- the entry refuses, before bootstrap and before dispatch, an envelope path that
  resolves to any artifact destination the command could write — including both
  trace suffixes and the private-result recovery name derived from the run
  reference — or to `init`'s target or a path beneath it. It reports an
  `:arguments` diagnostic, exits `2`, and delivers no envelope. Phase 6 remains
  envelope-blind;
- `help` and `version` reject `--envelope` as undeclared, like any other switch
  outside their declaration;
- `repl` accepts its own declared switches — including repeated ordered `--eval`
  and `--resource`, short aliases, and a positional script — rejects
  `--envelope` as undeclared, and lists all of them in its help topic;
- `--trace` is reported as retired for `run` with its replacement while
  remaining live for `repl`;
- `mix ptc <command>` reaches every engine command, and no guide instructs a
  reader to call `CommandEngine.dispatch/1` from `iex`;
- rendering matches byte-exact fixtures, identically under Mix and the release,
  for normal and private `run` success, each non-run command's success, one
  failure per `DiagnosticCatalog` phase, the five `:arguments` rejection shapes,
  the `74` destination failure, and a string value containing newlines;
- every failure rendering carries the run reference;
- every invocation that reaches a sealed outcome prints a readable rendering: a
  normal `run` prints its result value on stdout, a private `run` prints
  completion and artifact class without the value, and a failure prints phase,
  code, and message on stderr. Naming `--envelope` adds its atomic file
  publication without suppressing that rendering;
- `mix ptc run` renders identically to the release and no longer raises a JSON
  envelope as its error message, and `mix ptc.run` no longer exists;
- every documented recipe that parses command output names a destination rather
  than piping stdout. The retained workflow-testing recipe in
  [Running and debugging](../../guides/running-and-debugging.md) pipes the run
  command into `jq`, which this contract makes unsupported; it must move to
  `--envelope`, address the value through its real envelope path, and use the
  surviving `mix ptc run` spelling;
- the guide explains how to diagnose a failed run — where a workflow's own
  failure text and a compile error's detail actually live, given the closed
  public catalog. This documents behavior Checkpoint E already shipped and
  depends on no F or G code, so it may land as independent documentation work
  at any point before this gate;
- every command's help enumerates its accepted switches from the same parser
  declaration that accepts them, and a rejected or retired switch is named as
  such from a closed table;
- every command's exit status matches its outcome and the diagnostic catalog;
- `help` and `version` complete without starting the core or reading
  configuration;
- a detached standalone invocation refuses a private manifest REPL before
  phase 7; and
- `mix precommit` and `MIX_ENV=dev mix docs --warnings-as-errors` pass.

Packaged conformance on distribution targets belongs to Checkpoint G.

## Checkpoint G: macOS and container distribution

Checkpoint G distributes the Checkpoint F release. Its scope is deliberately
narrow: a locally built macOS command and a container image. Signed downloads,
notarization, a package manager formula, and single-file packaging are not in
scope and are recorded as deferrals.

### G1. Build targets

A release that includes the runtime cannot be cross-compiled; each target
builds on its own operating system and architecture. The launcher release
workflow already runs the required matrix — `ubuntu-22.04`,
`ubuntu-24.04-arm`, `macos-15`, and `macos-15-intel`. Checkpoint G reuses that
matrix shape rather than inventing a second one, and keeps the existing tagged
release gate as the entry point.

macOS ships both architectures. The command is unsigned, so a copy that
acquires the quarantine attribute will be refused by the operating system. The
supported macOS path is therefore a locally built release. Say this in the
documentation instead of implying a downloadable command exists.

### G2. Container image

The image uses a glibc base. The launcher companion is C compiled against the
build image's C library, so a musl-based runtime image would not run it; the
build and runtime images must share a C library.

The image must:

- contain the release, its included runtime, and the launcher companion
  required for stdio MCP;
- run as a non-root user;
- declare a working directory for mounted manifests, host documents, and the
  envelope destination; and
- carry no credential, no `.env`, and no default host document.

### G3. Distribution evidence

Packaged tests cover, on each target:

- every grammar command runs from the packaged command;
- the envelope destination writes one schema-valid envelope inside the
  container's mounted directory and on macOS;
- exit statuses survive the packaging boundary;
- the interactive command works from a packaged invocation with an attached
  terminal, and a detached packaged invocation refuses a private manifest REPL;
- a stdio MCP source launches through the packaged launcher companion; and
- the retained V1 signal non-guarantees still hold — characterized, not
  promoted to a portable guarantee.

### Checkpoint G gate

Checkpoint G is complete when the packaged evidence passes on each named target
— macOS arm64, macOS x86_64, and the container image on both `linux/amd64` and
`linux/arm64` — the documentation states the unsigned macOS limitation, and no
distribution step depends on signing, notarization, a package manager, or
single-file packaging. Name the architectures rather than saying "the container
image": the release embeds a runtime built for one architecture, so an image is
a per-architecture artifact and a gate that does not say which ones is not
checkable.

## Checkpoint H: acceptance and documentation

Checkpoint H reconciles the implementation with retained documentation and
runs the complete acceptance matrix:

- update CLI, host-configuration, Kernel-maintainer, OAuth, REPL, and packaging
  documentation, including the rewritten standalone process contract and the
  unsigned macOS limitation;
- confirm the failed-run diagnosis guidance required by the Checkpoint F gate is
  present and still accurate, and give the retained tracing conventions — a
  run's `--trace-dir` naming against the REPL's explicit trace path — their
  rationale rather than leaving them reading as an inconsistency;
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

The completed E–H work must demonstrate:

- one shared parser and command semantic implementation for Mix and standalone,
  except for the explicit Mix-only authorization option;
- memory and directory packages produce identical identities and behavior;
- provider-free commands perform no provider, credential, OAuth,
  provider-owned process/port, or network work;
- provider activity changes only from false to true at the active boundary;
- a manifest REPL uses one provider session for its lifetime and shares the
  one-shot cleanup and caller-death guarantees;
- private manifest REPL values reach only an explicitly authorized destination,
  and a detached, scripted, stdin, eval, load, or JSONL invocation is refused.
  This is accident prevention, not access control: terminal detection is
  defeatable and a same-uid caller can read the artifact directly, so the
  property to demonstrate is consistent refusal, not containment;
- public envelopes contain no private data, path, credential, arbitrary term,
  selector, or raw provider response;
- private results cannot succeed without an authorized owner-only sink;
- provider cleanup precedes final result publication;
- `init` never merges with, overwrites, recursively deletes, or removes a
  concurrently replaced filesystem entry;
- a named envelope destination receives exactly one schema-valid envelope,
  committed atomically without replacement, and neither stream ever carries an
  envelope;
- both process streams are explicitly non-contractual. The command's own
  rendering and diagnostics are closed and carry no private value, credential,
  path, selector, or arbitrary term — but the streams are shared with the
  runtime, its optional applications, and their children, and withdrawing the
  wrapper withdrew the sentinel matrix that policed them. Neither content nor
  secrecy is promised for what other code writes there. A deployment that needs
  a guarantee on those streams must capture them outside the command;
- exit status, startup identity, and the interactive command conform on every
  distribution target while signals retain their explicit non-guarantee; and
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
- standalone interactive OAuth authorization, and durable storage of refresh
  tokens or grant state — see the separately triggered grant-cache note below,
  which reuses an existing authorization rather than performing one;
- a two-phase, hard-cancellable host-runtime activation protocol;
- a new LLM adapter or removal of `req_llm`/`llm_db`;
- a second general HTTP stack;
- hostile same-user or same-VM containment;
- portable signal cleanup guarantees;
- a guaranteed byte-pure machine channel on piped standalone stdout, and the
  native outer wrapper, private envelope descriptor, and stderr sentinel matrix
  that would be required to promise one;
- code signing, notarization, a signed downloadable command, a package-manager
  formula, and single-file packaging;
- distribution targets beyond macOS and a glibc container image; and
- backward-compatible CLI aliases.

Use the [durable OAuth store plan](../future/mcp-oauth-durable-store.md) only
when a real durable adapter is chosen. Define hosted-service and outer-supervisor
security at the boundary where those deployments actually exist.

One deferral now has a trigger, and it is deliberately **not** work this plan
owns or gates. Checkpoint G ships a packaged command that disables interactive
authorization, so an OAuth-protected MCP installation is unusable from a
container even after someone has authorized it through Mix.

An access-token-only grant cache would turn that from a wall into a setup step —
authorize once on a workstation, run anywhere until expiry. It does not perform
an authorization, which is why it does not contradict the deferral above, and it
persists no refresh token: `refresh_access` defaults to `"none"` and the token
manager already has a first-class refresh-less path, so a default installation
never holds one to persist.

It is also not the durable store plan and not a second `Store` adapter. That
vocabulary holds live worker pids, grants enter memory only through the leased
commit sequence, and no `GrantKey` is constructible outside the OAuth path, so
the shape is two new closed store operations plus a frontend-owned cache file —
not an adapter swap.

Record it as its own slice plan, land it as its own PR, and keep it out of every
checkpoint and gate in this document. It is a different resource model, nothing
in F, G, or H depends on it, and this plan's completion criterion is unaffected
by whether it ships.

## Completion criterion

This plan is complete when Checkpoints E, F, G, and H are delivered, all
replaced frontend and REPL paths are absent, every checkpoint has a clean
exact-tree review, repository and packaged gates pass after the final rebase,
and retained documentation describes the shipped command rather than this plan.
