# Profile-Backed `mix ptc.repl`

Status: implemented and verified 2026-07-20. Three independent Codex passes
were applied: the plan review closed lifecycle, physical-path, privacy, and
documentation gaps; implementation reviews closed persistence-retry,
canonical-ancestry, race-safe publication, profile-discovery, bounded-input,
negated-option, test-validity, and JSONL-contract gaps.

Scope: `ptc_runner`; `ptc_viewer` receives only the internal builder migration
and regression coverage required to keep its existing behavior

Purpose: let humans and coding agents use the terminal REPL to run the same
bounded `log-analysis-v1` mission session as the Viewer, without turning
`mix ptc.repl` into an MCP service or exposing caller-defined capabilities,
preludes, or limits.

## Outcome

Add an explicit profile-backed mode to `mix ptc.repl`:

```console
mix ptc.repl \
  --profile log-analysis-v1 \
  --resource traces=tmp/tutorial-traces
```

The command starts one `PtcRunner.Kernel.LogAnalysisSession`, captures the
selected trace directory immutably, and evaluates every loaded or entered form
through the mission evaluator. Definitions, `*1`/`*2`/`*3`, budgets, and the
mission continuation are shared for the lifetime of the command. The terminal
is a frontend over the existing session owner; it does not reimplement the
Viewer over HTTP and does not wrap the workflow `ReplSession`.

The ordinary direct and manifest-backed REPL remain workflow scratchpads with
their current behavior. Profile mode is selected only by `--profile` and is
mutually exclusive with `--manifest`.

For coding agents, profile mode also provides deterministic JSON Lines output,
repeatable non-interactive evaluation, an opt-in continue-after-form-error
policy, stable error categories, and a safe profile-description command. It
does not add MCP, a daemon, authentication, or remote access.

## Verified Current State

The implementation starts from these verified facts:

- `Mix.Tasks.Ptc.Repl` accepts repeated `--eval`, one `--load`, a positional
  script or stdin, `--manifest`, and optional `--trace` persistence.
- All current modes use `PtcRunner.Kernel.ReplSession`, which evaluates the
  workflow environment directly. Successful forms preserve definitions and
  exact `*1`/`*2`/`*3` history; failed forms preserve the last committed state.
- `ReplSession` cannot be wrapped to obtain mission-equivalent evaluation. It
  reserves the continuation lease before evaluating, so a nested
  `kernel/eval-source` attempts to reserve the same lease and returns `:busy`.
- `PtcRunner.Kernel.LogAnalysisSession` is the existing serialized owner for
  multi-form mission evaluation. It uses `PtcRunner.Kernel.Evaluation`, returns
  bounded public projections, and keeps the session open after ordinary
  success, explicit `return`, explicit `fail`, and recoverable evaluator error.
- `PtcRunner.Kernel.LogAnalysisProfile` is the only session profile. Its stable
  ID is `log-analysis-v1`; it installs only `log.core`, grants the four
  snapshot-backed trace capabilities, fixes limits and result policy, and
  includes its authority in a persisted profile digest.
- `PtcRunner.Kernel.LogAnalysisSessionBuilder` currently accepts one trace
  directory, captures it, and writes the analysis session trace back into that
  same directory under a `viewer-repl-*` run ID.
- `PtcRunner.Kernel.SessionTrace` owns finalization and atomic no-clobber
  publication. Its destination basename is the generated run ID plus
  `.jsonl`; persistence retry remains with the live session owner.
- `TraceSnapshot.info/1` exposes bounded capture identity and counts, not the
  host filesystem path.
- The Viewer already uses this profile and builder through an opaque Core
  session handle. The browser does not select the trace path, capabilities,
  components, limits, or profile contents.

This plan builds on the implemented multi-turn evaluation semantics recorded
in `repl-style-multi-turn-agent-loop.md` and the implemented Viewer session in
`viewer-log-analysis-repl-plan.md`. It does not reopen either design.

## Product Decisions

### First increment

- `log-analysis-v1` is the only accepted profile ID.
- `--resource NAME=VALUE` is repeatable, but this profile accepts exactly one
  required resource: `traces=DIR`.
- Resources are authority-bearing host inputs, not an untyped profile options
  map. Unknown, missing, or duplicate resources fail before any session starts.
- `--profile` and `--manifest` are mutually exclusive. `--resource` without a
  profile is invalid.
- Profile mode supports the existing input shapes: optional `--load`, repeated
  `--eval`, one positional script, stdin through `-`, and interactive input.
- Every source in one command uses one mission session and therefore one
  continuation and aggregate budget.
- Human-readable Clojure output remains the default.
- `--format jsonl` is initially available only in profile-backed,
  non-interactive mode. This keeps the machine stream free of prompts and does
  not silently define a second output contract for the workflow REPL.
- `--continue-on-error` is initially valid only with repeated `--eval` in
  profile mode. It continues after a non-terminal evaluation projection whose
  status is `error`; setup, input, terminal-budget, lifecycle, and persistence
  failures always stop.
- A failed form still yields a non-zero command result even if later forms run
  and succeed. This frontend result does not change the analysis session's
  canonical close policy: ordinary close may remain successful despite earlier
  per-form failures.
- Profile sessions always persist a separate canonical analysis trace. The
  captured input directory is never used as the default output destination.
- `--session-trace-dir DIR` selects the output directory for profile-session
  traces. If omitted, the task creates a private directory under the operating
  system temporary directory and reports the persisted file path on close.
- Existing workflow-mode `--trace FILE` semantics remain unchanged. In profile
  mode `--trace` is rejected in favor of `--session-trace-dir`, avoiding one
  flag whose value means a file in one mode and a directory in another.
- `--describe-profile log-analysis-v1` reports the safe, code-owned contract
  without capturing resources or starting an evaluation session.
- Session metadata and run IDs become frontend-neutral: use a
  `log-analysis-*` run ID prefix and a `ptc.log-analysis.repl` label rather
  than Viewer-specific names. Viewer and terminal sessions deliberately share
  the same authority identity.

### Explicitly out of scope

- A generic `SessionProfile` behaviour, dynamic registry, plugin system, or
  JSON/YAML profile definition.
- Any profile other than `log-analysis-v1`.
- Caller-selected components, preludes, capabilities, mission data, limits,
  persistence policy, result projection, or canonical labels.
- Arbitrary `--config KEY=VALUE` profile parameters.
- Private inspection artifacts or capabilities over them.
- MCP, HTTP, WebSocket, daemon, or remote terminal protocols.
- Roles, users, tenants, authentication, and authorization policy.
- Multiple concurrent sessions inside one command.
- Checkpointing or resuming a session across BEAM processes.
- Changing the Viewer UI or its browser-facing API.
- Making the direct workflow REPL use mission semantics by default.
- JSONL output for direct or manifest-backed workflow mode.

These are deliberate boundaries, not missing extension points. A second real
profile should supply evidence for any shared profile abstraction. A remote or
multi-user frontend needs a separate plan because it introduces identity,
resource authorization, concurrency, revocation, and transport concerns that a
local command does not have.

## User Experience

### Interactive log analysis

```console
$ mix ptc.repl --profile log-analysis-v1 \
    --resource traces=tmp/tutorial-traces
PTC-Lisp REPL [log-analysis-v1] (Ctrl+D to exit; :help for commands)
ptc> (def runs (log/runs {}))
...
ptc> (count (get runs "items"))
3
ptc> (map #(select-keys % ["run_id" "status" "duration_ms"])
...>      (get runs "items"))
...
Goodbye!
Analysis trace: /private/tmp/ptc-repl-.../log-analysis-....jsonl
```

The startup banner identifies the profile but does not print the source path.
Intentional Lisp prints appear before the formatted value, as in the current
REPL. Evaluation errors are readable and the interactive session continues
while its lifecycle remains open.

The existing `:doc`, `:find`, and `:help` commands remain available.
Profile-mode `:help` additionally states the profile ID, the available
`log.core` component and exported `log` namespace, and how to inspect remaining
usage. It must not claim
that terminal commands are PTC-Lisp forms.

### Non-interactive human use

```console
mix ptc.repl \
  --profile log-analysis-v1 \
  --resource traces=tmp/tutorial-traces \
  -e '(def runs (log/runs {}))' \
  -e '(count (get runs "items"))'
```

`--load FILE`, a positional script, and stdin are evaluated in the same
profile session as later expressions or interaction. A load failure is a setup
failure and never proceeds to later expressions.

### Coding-agent use

```console
mix ptc.repl \
  --profile log-analysis-v1 \
  --resource traces=tmp/tutorial-traces \
  --session-trace-dir tmp/agent-analysis-traces \
  --format jsonl \
  --continue-on-error \
  -e '(def runs (log/runs {}))' \
  -e '(count (get runs "items"))'
```

The agent can send several `-e` arguments without managing a PTY. Each record
on task stdout is one complete JSON object. Diagnostics from the task go to
stderr. After Mix startup, the task emits no banners, `Loaded ...` notices,
prompts, or raw Clojure values to stdout in JSONL mode.

The task uses the ordinary Mix process exit contract:

- zero means setup, every requested evaluation, close, and persistence
  succeeded;
- non-zero means CLI validation, setup, input, evaluation, lifecycle, or
  persistence failed.

Do not call `System.halt/1` from the Mix task. Tests must be able to invoke the
task in-process; a raised `Mix.Error` supplies the non-zero shell result.

### Profile discovery

```console
mix ptc.repl --describe-profile log-analysis-v1
mix ptc.repl --describe-profile log-analysis-v1 --format jsonl
```

The description includes:

- profile ID and human summary;
- required resources and their kinds;
- installed component and namespaces;
- explicit capability names;
- fixed limits;
- persistence and result policies;
- supported frontend modes and output formats.

It excludes callbacks, source paths, snapshots, process identifiers, native
terms, exact trace contents, credentials, and generated/evaluated source. The
effective session digest is reported only by a started session because it is
derived from the compiled bundle and mission inventory; the static description
must not invent one.

`--describe-profile` is exclusive with `--profile`, `--resource`, `--manifest`,
`--load`, `--eval`, script/stdin, `--trace`, `--session-trace-dir`, and
`--continue-on-error`. It accepts the default human format or `jsonl`.

## Command-Line Contract

Add these strict switches to `Mix.Tasks.Ptc.Repl`:

| Switch | Value | Contract |
| --- | --- | --- |
| `--profile` | profile ID | Select one code-owned profile; initially only `log-analysis-v1` |
| `--resource` | `NAME=VALUE` | Repeatable profile resource; split on the first `=` |
| `--session-trace-dir` | directory | Existing normal directory for a profile session's separate output trace |
| `--format` | `clojure` or `jsonl` | `clojure` default; `jsonl` only for non-interactive profile execution or profile description |
| `--continue-on-error` | boolean | Continue failed repeated evaluations in profile mode |
| `--describe-profile` | profile ID | Describe a supported profile without starting it |

Keep all existing switches and short aliases. Do not add short aliases for the
new switches.

Resource parsing follows a closed contract:

1. Split on the first `=` so a path may contain later equals signs.
2. Require a non-empty bounded ASCII name and a non-empty valid UTF-8 value.
3. Reject duplicate names rather than choosing first or last.
4. Resolve the profile ID to a code-owned resource contract.
5. Reject missing and unknown resource names.
6. For `log-analysis-v1`, expand `traces` locally and require a normal
   directory before calling the builder.
7. Do not include the expanded path in the profile digest, canonical labels,
   session info, or evaluation records.

The first increment does not support shell interpolation or environment
variable syntax inside values. The shell may perform its normal expansion
before the task receives the argument.

Validation occurs before reading `--load`, capturing traces, compiling a
profile bundle, starting an owner, or creating an output directory. The task
must reject at least these combinations:

- `--profile` with `--manifest` or `--trace`;
- any `--resource` or `--session-trace-dir` without `--profile`;
- `--continue-on-error` without profile mode and repeated `--eval`;
- `--format jsonl` with interactive mode;
- `--eval` with positional script/stdin, preserving current behavior;
- more than one positional argument;
- any runtime option with `--describe-profile`.

## Authority and Ownership

| Concept | Authoritative owner or representation | Terminal responsibility |
| --- | --- | --- |
| Profile recipe | `LogAnalysisProfile` code for `log-analysis-v1` | select by exact ID only |
| Resource schema | safe descriptor exported by `LogAnalysisProfile` | parse and validate names; never assemble authority |
| Frozen input | `TraceSnapshot` owner | supply the host path once at construction |
| Mission environment and profile digest | `LogAnalysisSessionBuilder` plus `LogAnalysisProfile` | none |
| Continuation, evaluation lease, and budgets | one `RunState` owned through `SessionTrace` | serialize calls through `LogAnalysisSession` |
| Evaluation lifecycle | `LogAnalysisSession` GenServer | call evaluate/close/abort; do not mirror state |
| Canonical batch and publication retry | `SessionTrace` | choose a separate output directory and surface close result |
| Human or JSONL presentation | `Mix.Tasks.Ptc.Repl` frontend | format bounded public projections only |

The task process is the stable lifecycle owner for the builder-created
session. It must retain ownership for the whole input loop and use one cleanup
path for normal completion, exceptions, throws, input failure, and user
interrupt. It must never perform a separate read followed by update against an
owner process.

The terminal receives only public session handles and bounded projections. It
must not receive the snapshot token, `RunState`, event sink, mission
environment, capability callbacks, or native continuation memory.

## Core Changes

### 1. Separate captured input from trace output

Change `LogAnalysisSessionBuilder` so the host chooses an output directory
separately from the snapshot source. Use this explicit production entry point,
whose arguments cannot carry profile internals:

```elixir
LogAnalysisSessionBuilder.start(
  {:directory, input_directory},
  {:directory, output_directory}
)
```

The accepted production inputs are only one normal source directory and one
normal output directory. Move test-only fault hooks to an undocumented
`start/3` used by tests; do not overload the production destination argument
with a keyword options map. Do not expose components, capabilities, limits,
labels, or profile ID through either entry point.

The builder generates one `log-analysis-<random>` run ID and passes
`OUTPUT_DIR/<run-id>.jsonl` to `SessionTrace`. This preserves the existing
basename/run-ID and no-clobber invariants. It validates the output directory
before allocating session owners. It does not create arbitrary caller paths.

Migrate the Viewer worker to pass its host-selected trace directory as both the
input and output directories, preserving the existing Viewer product decision
that a refreshed session can inspect the preceding analysis trace. The CLI
always passes distinct directories and verifies this before construction.

Because this is a 0.x internal API, migrate all callers and tests to the one
explicit contract and delete the implicit destination behavior rather than
keeping a compatibility wrapper.

### 2. Make the profile identity frontend-neutral

Update `LogAnalysisProfile` documentation and fixed safe labels from Viewer
terminology to log-analysis terminology. Use:

```elixir
labels: %{
  "name" => "ptc.log-analysis.repl",
  "tags" => %{"mode" => "repl"}
}
```

Do not add an arbitrary `frontend` tag or caller-supplied labels. The profile
ID and digest remain `log-analysis-v1` and continue to attest the components,
capabilities, inventory, limits, and policies. The local resource path and
frontend transport are not authority ingredients and do not enter the digest.

Add a safe static profile description or equivalent closed projection to
`LogAnalysisProfile`. Its resource section is exactly:

```elixir
%{
  "traces" => %{
    "required" => true,
    "kind" => "normal-trace-directory",
    "summary" => "Immutable capture of canonical sanitized trace files"
  }
}
```

This is metadata for local validation and discovery, not a callback registry.
The builder remains the only authority assembler.

### 3. Add the terminal profile path

Keep workflow mode and profile mode as explicit branches in
`Mix.Tasks.Ptc.Repl`. Do not introduce a common session behaviour merely to
hide that their semantics differ.

The profile branch:

1. validates the complete CLI combination;
2. resolves and validates the closed resource set;
3. chooses or creates a distinct output trace directory;
4. starts one `LogAnalysisSession` through the builder;
5. evaluates optional load input and the selected input mode sequentially;
6. presents only the session's public projections;
7. closes and persists once;
8. reports the output trace path returned from frontend-owned construction
   state, not from a newly broadened Core info projection;
9. always calls `LogAnalysisSession.stop/1` after orderly close or abort in a
   common `after` cleanup path, including when presentation or error reporting
   raises.

The task may extract a separate terminal presentation module if the Mix task
would otherwise become difficult to review. Any such module remains a terminal
adapter and must not become a second session owner or profile registry.

Use the existing source scanner for multiline interactive input and existing
`:doc`/`:find` commands. Route evaluation to `LogAnalysisSession.evaluate/2`
only in profile mode. Never call `kernel/eval-source` from `ReplSession`.
Read load files, scripts, and stdin only up to the profile source ceiling plus
one bounded overflow unit, and stop accumulating interactive input at that
same ceiling before calling the evaluator.

### 4. Preserve one continuation across all input forms

The optional load file is the first evaluation in the same mission session. Later
`--eval` forms, a script, stdin, or interactive forms see its committed
definitions. Repeated `--eval` forms run in argument order.

For each `LogAnalysisSession.evaluate/2` reply:

- print every bounded `prints` entry first in human mode;
- print `formatted` when it is available;
- otherwise print a stable unavailable marker and the bounded error;
- treat projection `status: :ok` as a successful command evaluation;
- treat projection `status: :error` as a failed command evaluation;
- after a failure, continue only under the explicit policy above and only if
  `LogAnalysisSession.info/1` confirms an open lifecycle;
- never reconstruct or mutate continuation state in the task.

`continuation_effect` remains the authoritative feedback about whether the
form committed or preserved state. The frontend should show it in structured
output and may include a concise human hint on errors; it must not infer this
from the error kind.

### 5. Add strict JSONL presentation

Use deterministic JSON encoding over JSON-safe public projections. Atom keys
and values must be normalized to stable strings before encoding. Every record
contains a schema version and type.

Session-start record:

```json
{"schema_version":1,"type":"session-started","profile_id":"log-analysis-v1","profile_digest":"sha256:...","session_id":"log-analysis-...","namespaces":["log"]}
```

Evaluation record:

```json
{"schema_version":1,"type":"evaluation","index":1,"input_kind":"eval","result":{"status":"ok","outcome":"continued","continuation_effect":"committed_with_history","value":3,"value_available":true,"formatted":"3","formatted_truncated":false,"prints":[],"prints_truncated":false,"error":null,"evaluation_id":"...","duration_ms":4,"usage":{}}}
```

Close record:

```json
{"schema_version":1,"type":"session-closed","status":"ok","trace_path":"/absolute/output/log-analysis-....jsonl","session":{"lifecycle":"closed","evaluation_count":2,"terminal_reason":null,"trace":{"persistence":"persisted","event_count":8}}}
```

Terminal error record:

```json
{"schema_version":1,"type":"command-error","category":"evaluation","message":"one or more evaluations failed","evaluation_indexes":[2]}
```

The examples define shape, not literal usage contents. `session-started` is
present only after construction and `session-closed` only after successful
persistence; validation can therefore emit only `command-error`, while a
persistence error follows any earlier lifecycle records without a close
success claim. The implementation must publish one exact schema in the Mix
task documentation and integration tests.
Use snake-case JSON keys consistently. Do not add a raw source field, an
independent copy of evaluated source, load paths, resource paths, stack traces,
native terms, or exception inspection to JSONL records. A program may
intentionally return, print, or trigger a bounded evaluator message containing
text that also appeared in its source; those existing public result fields are
not a confidentiality boundary. `trace_path` is intentionally included in the
final local CLI record because it is required to consume the produced artifact.

Stable command-error categories are:

- `cli` — invalid options, combinations, profile, or resource declaration;
- `setup` — unreadable load/input, unavailable source capture, compilation, or
  session construction;
- `evaluation` — one or more requested forms returned an error projection;
- `lifecycle` — the session became terminal or its owner failed unexpectedly;
- `persistence` — finalization or trace publication failed;
- `frontend` — unexpected terminal adapter exception or input failure.

These categories are a CLI presentation contract, not new Kernel error atoms.
Human-mode errors retain useful bounded details while avoiding inspected
internal state.

When continuing after evaluation errors, emit every evaluation record, attempt
normal close, emit the successful close record if persistence succeeds, then
emit one final `command-error` summary and raise. This lets an agent consume
all feedback and the canonical trace while still observing a failing process.

### 6. Handle temporary output safely

When `--session-trace-dir` is absent, create a new private directory below
`System.tmp_dir!/0` with mode `0700`. The generated session trace is retained
after the task exits and its absolute path is reported. Do not delete a
successfully persisted trace during cleanup.

If temporary directory creation succeeds but session construction fails before
publication, remove only that exact task-created empty directory. Never
recursively delete a caller-supplied directory. Validate all deletion targets
against the exact path returned by the creation operation.

Caller-supplied output directories must already exist and be normal
directories. The terminal must prove physical separation before construction:

- resolve symlinked parents for both directories and compare their canonical
  physical paths;
- reject the same directory, an output directory beneath the input directory,
  or an input directory beneath the output directory;
- compare available filesystem identity fields as a second same-directory
  check rather than relying only on path text;
- bind the accepted output-directory identity into the session trace and use a
  directory-bound publication helper whose working-directory identity is
  verified before it receives trace bytes, so pathname replacement cannot
  redirect publication;
- fail closed when physical identity or ancestry cannot be established.

This prevents a symlinked parent or nested output from writing into the
analyzed tree. The builder's atomic no-clobber publication remains authoritative
for the final file.

## Failure, Interrupt, and Cleanup Semantics

| Failure point | Required behavior |
| --- | --- |
| CLI/resource validation | no snapshot, owners, or output directory created |
| Input capture/profile construction | builder cleans partial owners and snapshot; task cleans only its empty temporary output directory |
| Load read/evaluation failure | close and persist if a session exists; do not evaluate later inputs |
| Repeated evaluation failure without continue | stop evaluating, close and persist, report failure |
| Repeated evaluation failure with continue | preserve state, continue while open, close and persist, then exit non-zero |
| Terminal Kernel budget or deadline | stop new evaluations; surface lifecycle; close/retry persistence as supported |
| Ctrl+D in interactive mode | normal close and persistence, followed by explicit session stop |
| Ctrl+C, throw, or frontend exception | abort with a bounded frontend reason, then explicitly stop the session in `after`; never leave a live owner intentionally |
| Persistence failure | surface `persistence`; retain retry authority only while the live session permits it; do not claim success or delete artifacts |

The terminal makes one initial normal-close attempt. If it reports a retryable
retained persistence failure, the task performs at most one explicit close
retry before failing; it must not loop indefinitely or retry again through its
exception cleanup. Existing
`SessionTrace` idempotence ensures retry does not append events or emit a
second terminal event. Whether close succeeds or fails, the task finally calls
`LogAnalysisSession.stop/1`; close and abort alone do not terminate the session
GenServer or its `SessionTrace` owner.

## Documentation Changes During Implementation

When the feature is implemented:

- update `Mix.Tasks.Ptc.Repl` module documentation with the exact switches,
  combinations, examples, JSONL schema, and exit behavior;
- update `docs/guides/kernel-repl.md` with direct, manifest, and profile mode,
  making their workflow/mission distinction explicit;
- update `LogAnalysisProfile`, `LogAnalysisSessionBuilder`, and
  `LogAnalysisSession` module documentation with their durable contracts;
- update `docs/guides/kernel-maintainer.md` and
  `docs/trace-log-contract.md` so they describe a local profile-specific
  session shared by the Viewer and terminal, while distinguishing Viewer
  same-directory refresh from terminal separate-directory persistence;
- update other Viewer-facing durable documentation where the neutral run ID
  and label replace Viewer-specific terminology;
- do not link production code documentation to this plan;
- do not change the PTC-Lisp specification because no language syntax or
  evaluator semantics change.

Include a short coding-agent recipe showing repeated `-e`, JSONL parsing, and
the separate session trace. Also include a human example that uses `log/runs`,
filters its `"items"`, and then drills into one run or its turns.

## Implementation Slices and Review Gates

### Slice 1: CLI grammar and safe discovery

- Add strict option parsing and combination validation.
- Add the profile's safe resource/description projection.
- Implement human and JSONL `--describe-profile` output.
- Add option-table and description privacy tests.

Review gate: no resource path is read and no owner starts during description or
failed validation; ordinary REPL parsing remains unchanged.

### Slice 2: Decoupled builder destination

- Give the builder explicit source and output directories.
- Make run IDs and labels frontend-neutral.
- Migrate the Viewer worker and all builder tests.
- Prove no-clobber publication and source/output separation.

Review gate: owner transfer, partial-construction cleanup, persistence retry,
and Viewer close/reset behavior retain their existing guarantees.

### Slice 3: Human terminal profile mode

- Start and retain one mission session from the Mix task.
- Support load, repeated eval, script, stdin, and interactive input.
- Format bounded projections and close through one cleanup path.
- Preserve ordinary and manifest-backed workflow behavior exactly.

Review gate: tests demonstrate one continuation, rollback after failed forms,
aggregate budgets, and separate trace persistence.

### Slice 4: Coding-agent contract

- Add deterministic JSONL records.
- Add continue-on-error for repeated evaluations.
- Stabilize error categories and stdout/stderr separation.
- Add actual subprocess smoke coverage for exit status and parseable output.

Review gate: every task-emitted stdout line parses as JSON in JSONL mode; all
failures remain non-zero without calling `System.halt/1`.

### Slice 5: Durable docs and end-to-end verification

- Update the REPL guide and module docs.
- Add copy-paste human and coding-agent examples.
- Run root and Viewer quality gates.
- Exercise a real trace directory using the installed Mix command.

Review gate: the docs accurately distinguish workflow and mission modes and do
not present plan text as an implemented contract before the code lands.

## Test Matrix

### CLI and regression tests

- ordinary `mix ptc.repl`, manifest, `--load`, repeated `-e`, scripts, stdin,
  interactive EOF, and `--trace FILE` retain current tests and output;
- valid profile/resource combinations select mission mode;
- missing, unknown, duplicate, malformed, or invalid-UTF-8 resources fail;
- unsupported profile IDs fail without starting owners;
- every prohibited option combination fails before side effects;
- profile description is safe in both output formats;
- JSONL interactive use is rejected.

### Session and semantics tests

- load definitions are visible to later evaluations;
- repeated definitions and `*1`/`*2`/`*3` share one continuation;
- an undefined-variable or runtime error preserves earlier definitions;
- `return` and `fail` are per-form outcomes and do not by themselves end an
  otherwise open session;
- aggregate evaluation and capability budgets span all forms;
- a terminal budget prevents later evaluation;
- `--continue-on-error` runs later forms against the preserved state and exits
  non-zero after successful close;
- without the flag, the first failed repeated form stops later evaluation.

### Persistence and lifecycle tests

- the source trace directory listing and bytes are unchanged by terminal
  profile analysis;
- explicit and temporary output directories receive exactly one
  `<run-id>.jsonl` file;
- the persisted file is canonical and reloadable through `TraceLog`;
- its run metadata contains the profile ID and digest and uses neutral labels;
- output publication remains atomic and no-clobber;
- close retry does not duplicate terminal events;
- partial builder failure and frontend exception stop all owned processes;
- successful close, evaluation failure, input failure, persistence failure, and
  presentation exception all terminate the session and trace-owner processes;
- caller-supplied directories are never deleted;
- nested output directories, same-directory filesystem aliases, and symlinked
  parent aliases are rejected before session construction;
- replacement of the accepted output directory identity is rejected inside
  trace publication;
- load files, scripts, stdin, and interactive buffers are rejected at the
  profile source ceiling without first loading an unbounded source;
- temporary-directory cleanup targets only an empty directory created by the
  current task;
- Viewer sessions still capture and publish according to their existing
  close/reset/shutdown contract.

### Machine-output tests

- each task-emitted stdout line decodes independently as JSON;
- conditional record order is session-started, evaluations in source order,
  a successful session-closed, and a required command-error summary on failure;
- prints are fields inside the evaluation record, not separate raw lines;
- stderr diagnostics never appear in stdout capture;
- no record contains a raw source field or independent source copy, input/load
  paths, callback/native values, process IDs, stack traces, credentials, or
  unrelated trace contents; use a sentinel that the program neither returns
  nor prints when testing absence of source copies;
- subprocess success returns zero and validation, evaluation, and persistence
  failures return non-zero;
- the final trace path exists and points outside the captured source directory.

Do not use `Process.sleep/1`. Use monitors, owner info calls, fault hooks, and
eventual assertions tied to explicit process transitions.

## Acceptance Criteria

Implementation is complete only when all of the following hold:

1. The example `--profile log-analysis-v1 --resource traces=DIR` command works
   in interactive and non-interactive human modes.
2. Ordinary and manifest-backed `mix ptc.repl` behavior is unchanged.
3. Profile and manifest authority cannot be combined, and the caller cannot
   select profile internals.
4. Exactly one required `traces` resource is validated before session start.
5. All forms in one command share one mission continuation and aggregate
   budget; failed forms preserve prior committed state.
6. Profile mode reuses `LogAnalysisSession` and `Evaluation`; it does not wrap
   `ReplSession` or add a second evaluator.
7. The analyzed directory is not modified by terminal profile mode.
8. The separate analysis trace is atomically persisted, canonical, reloadable,
   and reports `log-analysis-v1` plus its effective digest.
9. JSONL output is parseable line by line, contains bounded public projections,
   and is free of prompts and raw diagnostics.
10. Continue-on-error preserves later feedback while the final process remains
    non-zero after any requested form fails.
11. Safe profile discovery exposes resources, capabilities, preludes,
    namespaces, limits, and policies without paths, callbacks, source, native
    state, or secrets.
12. Interrupt, exception, deadline, terminal budget, and persistence failure
    paths stop or transfer every owner according to the existing lifecycle
    contract, and the terminal explicitly stops the session after every normal
    close or abort.
13. Viewer log analysis retains its existing browser behavior after the
    internal source/output builder migration.
14. An actual shell invocation against a real canonical trace directory works
    for a coding agent without MCP or browser automation.
15. `mix precommit` passes, and Viewer changes are formatted and tested from
    `ptc_viewer/` as required by repository instructions.

## Follow-Up Decision Points

Do not implement these in this change, but retain the seams needed to evaluate
them later:

- A second independent profile can justify a small code-owned resolver or
  behaviour and reveal which fields are genuinely common.
- Remote Viewer or terminal access requires roles to select server-owned
  profiles and authorized resources; a role must never expand into a
  client-supplied capability list.
- Machine output for the workflow REPL should be considered only with its own
  result schema and regression plan.
- Resumable sessions require durable continuation, identity, revocation, and
  cleanup contracts rather than reusing this process-local CLI session.
- If exact evaluated PTC-Lisp source or model feedback must be retained, add a
  separately authorized private-inspection design; canonical logs remain
  payload-free.
