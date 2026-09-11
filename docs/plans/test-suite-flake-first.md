# Test suite: fix the flake classes first, then retire the serial tail

Status: draft, 2026-09-11. Tracking issue: #1913.

## Why this order

The suite is slow and flaky for the same reason. Tests that use the wall
clock as a synchronisation primitive fail under CPU contention, and the
workaround for that has been `async: false`. The serial modules now cost
more than everything else combined, and the flakes that remain live in the
async phase, so restructuring first would move deadline-sensitive modules
into contention and multiply the failures. Investigation comes first.

## Evidence (main, 0.15.0, 2026-09-10/11)

Measured with `PTC_PROFILE_SLOW=1 mix test` on a 10-core Mac, warm build.

| Measurement | Value |
|---|---|
| Wall time | 428 s |
| Async phase (314 files) | 115 s, ~7x parallel at `max_cases` 10 |
| Sync phase (~50 `async: false` files on the PR suite) | 313 s, 1x |
| Summed test time | 1,170 s |
| CI `test.yml` on `main`, last 60 runs | 53 pass, 7 fail |
| Flake-related commits in history | 54 |
| Deadlines of 500 ms or less passed to code under test | 105 sites |
| Assertions on elapsed wall time | 12 |
| `async: false` files that state why | 4 of ~50 |

Serial modules by time: MCPSourceTest 35 s, ReplFrontendTest 33 s,
ViewerFrontendTest 32 s, MCPStdioTransportTest 32 s, ExampleLibraryTest
25 s, QuickstartGuideTest 24 s, PublicationAuthorityTest 21 s,
CommandEngineGlobalStateTest 13 s, CommandMaterializeTest 11 s,
HostInstallationTest 11 s. The next floor after the tail is
`PtcRunner.GitHooks.PrePushTest`: 75 s of bash-spawning tests inside one
async module, and tests inside a module always run serially.

Reproductions this week:

- `repl_session_test.exs:451` failed in the full run (seed 869188), passed
  alone with the same seed, and passed 15 repeats of its file. Load flake,
  not order dependence.
- PR #1900 needed three CI attempts: `command_frontend_test.exs:781`
  (reservation reclaim, exit 2) and `analysis_session_test.exs:1396` (no
  `:DOWN` within 5 s). Both wait on OS work: the reclaim spawns `id`, `kill`
  and an `flock` helper; the session waits on owner cleanup.

## Flake classes

Every class below has already been root-caused at least once (PRs #1200,
#1206, #1286). The plan fixes classes, not individual tests.

| Class | Mechanism | Rule |
|---|---|---|
| A. Deadline under test | A small budget is handed to the code under test and the test asserts it expires or does not | The path that must expire is *held* (`:sys.suspend`, a stub that never answers), never merely slow. Margins are sized from measurement, as PR #1200 did. |
| B. Dead-process inspection | `:sys.get_state`, `:erlang.trace`, or `File.stat` on something that already finished; `:DOWN` ordering | Monitor before the action; `Task.await` spawned work; poll post-`:DOWN` state through `Eventually`. |
| C. OS work under load | Helper processes (`id`, `kill`, `flock`), fsync, owner cleanup inside a fixed window | Make completion observable (a message or a monitor), or give cleanup a budget that a 4-vCPU runner under load can meet. PR #1900's two failures are here. |
| D. VM-global state | `Application.put_env`, `System.put_env`, `File.cd`, `:persistent_term`, `Logger.configure`, fixed ports or paths | Keep serial, in the smallest possible module, with the reason on the `use` line. |
| E. Product bugs | A flake reporting a real defect (TokenManager wedge in #1286, RunCoordinator in #1206) | Expect a share of flakes to be defects. Never widen a timeout without naming the mechanism. |

## Phase 0: instrument (one small PR)

1. Record the wall/async/sync split, seed, scheduler count and failures
   per run. Extend `PtcRunner.TestSupport.SlowTestProfiler` or add a
   second formatter; write one JSON line per run and upload it as a CI
   artifact. Never `--slowest`; it pins `max_cases` to 1.
2. Add `scripts/ci/flake-hunt.sh N`: runs `mix test` N times with
   `--schedulers 4` (GitHub's CPU shape), a fresh seed each time, optional
   background CPU load, and prints a table of `{test, seed, message}`
   frequencies. Add a nightly job that runs it ten times on `main` so the
   flake rate per test becomes a number instead of a feeling.
3. Put a one-line reason on every `async: false` `use` line, naming the
   class (A to D). This is the inventory Phase 2 works from; a file that
   gets no honest reason is a candidate for the first tranche.

Gate: the nightly table exists and has a week of data.

## Phase 1: fix the classes

Order by evidence, not by module:

1. Class C first, because it is what CI is failing on now. Start with the
   two PR #1900 tests: read the reclaim path's budget for its helpers and
   what exit status 2 means there; read the owner-cleanup wait in
   `analysis_session_test.exs`. Fix the mechanism in `lib/` or the wait in
   the test, and write the rule down.
2. Class A: audit the 105 small-deadline sites, concentrated in
   `provider_session_test.exs` (26), `mcp_source_test.exs` (9),
   `dispatcher_llm_deadline_test.exs` (9), `core_contract_test.exs` (6).
   Each becomes either a held path or a deadline large enough that only a
   held path can reach it. The 12 elapsed-time assertions get the same
   treatment.
3. Class B: sweep for `:sys.get_state` and `:erlang.trace` on pids the
   test did not monitor first.
4. Write the rules into `docs/maintainers/development-setup.md` next to
   the existing `Process.sleep` rule, and encode what can be encoded as a
   support-level test (for example, no `refute_receive` without an
   explicit window in a serial module).

Gate: 20 consecutive `flake-hunt` runs at 4 schedulers on `main` with zero
failures, or every failure named with a class and a fix in flight.

## Phase 2: retire the serial tail in tranches

One PR per tranche. Each PR records the before and after split from
Phase 0 and passes ten `flake-hunt` runs.

| Tranche | Modules | Approach | Serial time freed |
|---|---|---|---|
| 1 | ReplFrontendTest, ViewerFrontendTest, ExampleLibraryTest, PublicationAuthorityTest | Move the few env-mutating tests into a `*GlobalStateTest` sibling, the pattern CommandEngine already uses; flip the rest to async | ~110 s |
| 2 | MCPSourceTest, MCPStdioTransportTest | Convert deadline assertions to class A held paths; keep any test whose contract is a true wall-clock bound in a small serial sibling | ~67 s |
| 3 | QuickstartGuideTest, TutorialCostBudgetTest, CommandMaterializeTest, Mix.Tasks.Ptc.MaterializeTest | These boot `mix` or `ptc` subprocesses. The repository rule already routes operator-path subprocess walks to `:nightly`; apply it, or run through the in-process command path where the guide contract allows | ~50 s |
| 4 | HostInstallationTest, ProviderActiveSessionTest, ManifestReplTest, the rest | Mostly `Application.put_env` fixtures. Where the code under test can take its configuration as an argument, do that; otherwise leave serial with the reason stated | ~40 s |

Expected result after tranches 1 to 3: roughly 255 s wall instead of 428 s.
Fully async: about 160 s, with PrePushTest as the floor.

## Phase 3: the next floor

`GitHooks.PrePushTest` (75 s), `Mix.Tasks.PtcTranscriptTest` (35 s),
`Scripts.WorktreeSeedTest` (33 s). Split each by scenario into several
modules so they overlap, or share one prepared repository per module
through `setup_all`. Only worth doing once Phase 2 makes them the floor.

## Phase 4: CI only

Add `--partitions 2` to the core test job in `test.yml`. Modules,
including the serial ones, split across two runners with no code change.
This does not help local runs or the pre-push hook, which runs the whole
suite before its concurrent lanes.

## Not doing

- Raising `max_cases`. The cap at `schedulers_online` is deliberate; the
  async phase is 115 s and is not the problem.
- Quarantine tags or automatic retries. The repository's stance since
  #1286 is to root-cause every flake, and a share of them are defects.
- Throttling the pre-push hook or lowering test concurrency to pass.

## Open questions

- Does the reservation reclaim path have a budget at all, or does it
  depend on the helpers returning promptly?
- How many of the 105 small-deadline sites are already held paths? The
  count is a grep, not an audit.
- Is a synthetic-load option in `flake-hunt.sh` needed, or is
  `--schedulers 4` on a 10-core machine enough to reproduce CI?
