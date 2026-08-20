# Faster git hooks and `mix precommit`

**Status:** active; slices 1, 2, and 3 implemented. Slice 7 started with
`command_engine_test.exs`. Measurements from a warm worktree on 2026-08-18
(Elixir on a 10-scheduler Mac, HEAD `d9a814b0`).

The three local gates are easy to conflate, and they do not cost the same:

| Gate | When | What it runs | Warm wall |
| --- | --- | --- | --- |
| `.githooks/pre-commit` | `git commit` | Staged-project format, compile, credo; scoped tests with `--exclude slow` | **13s** for static checks (target `<10s`) |
| `mix precommit` | agents, before a commit | Nested fetch + quality (`core-quality.sh`) | **~1 min** warm |
| `.githooks/pre-push` | `git push` | Docs, then core tests, then concurrent static+Dialyzer / release / Viewer, then launcher | **~6.8 min** when core is selected |

GitHub Actions runs the same scripts as parallel jobs. A typical core PR is
about **4.5 min** wall, with Core tests as the critical path (4:10 including
setup). Local push is slower because tests and the deterministic tail cannot
all start together.

## What was measured

Warm times in `/Users/andreasronge/projects/ptc_runner-perf-faster-hooks`
after the first compile in that tree. The first `mix compile --warnings-as-errors`
took 20s (seeded `_build` from the main checkout); a second compile took **2.7s**.

| Step | Seconds |
| --- | ---: |
| Mix boot (`mix help compile`) | 1 |
| `mix compile --warnings-as-errors` (truly warm) | 2.7 |
| `mix format --check-formatted` (776 files) | 2 |
| `mix format --check-formatted lib/ptc_runner.ex` | 0 |
| `mix credo --strict` (776 files) | 12 (later 9.5s analysis) |
| `mix credo --strict lib/ptc_runner.ex` | 1 |
| `mix xref` cycles | 3 |
| `mix ptc.validate_spec` | 2 |
| `mix ptc.gen_docs --check` | 3 |
| `mix ptc.conformance_report --check-inventory` | 3 |
| `scripts/duplication_gate.sh check` | 23 |
| `mix ptc.audit_upstream` | 8 |
| `mix deps.unlock --check-unused` | 0 |
| pre-commit `mix do format + compile + credo` | **13** |
| Viewer gate | 6 |
| Docs gate (`MIX_ENV=dev`) | 35 |
| Dialyzer | 62 |
| Core tests (`CI=1`) | **252** |
| Core release | **121** |
| Launcher `mix precommit` without `mix clean` | 31 |

Core tests printed:

```
Finished in 245.5 seconds (60.3s async, 185.2s sync)
6681 passed (122 doctests, 5 properties, 6554 tests), 368 excluded
```

The serial floor is **75% of suite wall**. Five StreamData properties are not
a meaningful lever; dropping `CI=1`'s 300-run setting would not change push
time in a way worth diverging from CI.

Reconstructed serial `mix precommit` (quality ≈ 50s after a warm compile):

```
preflight (~2) + quality (~50) + tests (252) + viewer (6)
+ launcher (~31, more with mix clean) + release (121)
≈ 462s
```

Reconstructed pre-push with core selected, after the existing concurrent tail
(`7c47dd4c`):

```
docs (35) + tests (252) + max(static+Dialyzer ≈ 120, release 121, Viewer 6)
≈ 408s
```

## Why overlapping more gates barely helps push

The pre-push tail already overlaps the three deterministic lanes. Two of those
lanes are the same length: static+Dialyzer (~120s) and release (121s). Static
analysis and Dialyzer share `_build/test` with the suite, so they cannot start
until tests finish. Release uses `_build/prod` and *could* overlap tests, but
that only shortens the tail from `max(120, 121)` to `120` — about one second.

Starting release during tests is also the load pattern the hook comments
refuse: timing-sensitive `async: false` tests have already flaked under
unrelated background work. Do not spend a slice on overlapping tests with
release or Dialyzer.

`mix precommit` used to run quality, tests, Viewer, launcher, and release
**back to back**. Slice 3 dropped the product gates from it. Concurrent lanes
for what remains would only overlap quality with nothing long enough to
matter.

## The expensive double run

Slice 3 removed the duplicated suite/Viewer/release loop. `AGENTS.md` now
asks for `mix precommit` (quality) before a commit and a full pre-push on
`git push`. An agent that follows both still repeats quality (~1 min), which
is the cheap half. `git push --no-verify` after a green `mix precommit` still
skips Dialyzer and ExDoc.

The git pre-commit hook is the fast commit path. `mix precommit` is quality
plus nested fetch.

## Serial tests, not Mix boots, dominate

- 250 files / 5541 tests are `async: true`.
- 59 files / 850 tests are `async: false` on purpose.
- 10 Lisp files / 523 tests used `use ExUnit.Case` with no `async:` option
  (slice 2 marked them `async: true`).

Largest remaining intentional serial CommandEngine module:
`command_engine_global_state_test.exs` (13 tests). The rest of that suite is
`async: true`.

## What not to do

- Do not lower ExUnit `max_cases` or add `--trace` / `--slowest` to make a
  gate look faster. `--trace` pins `--max-cases` to 1 (measured 259s on CI
  when that happened).
- Do not exclude `:slow` from pre-push or CI. That tag exists
  only for the git pre-commit hook; excluding it globally dropped correctness
  tests from every PR to save 14s.
- Do not tag in-process correctness tests `:nightly` to shrink the push suite
  (CommandEngine dispatch, TraceLog leases, pre-push classification). `:nightly`
  is for operator-path Mix/OS subprocesses and intentional multi-second waits;
  those stop being verified on pull requests. Measured 2026-08-18 on the
  expensive subset: five debug-a-failed-run `mix ptc run` tests summed to
  24.6 s, the 5.5 s parallel-ceiling park, inspection lab 4.2 s serial, and
  three Mix.Tasks.Ptc subprocesses ~11 s serial. `:slow` does not help push.
- CommandEngine's serial cost was mostly `JSV.build(CommandContract.schema())`
  on every `CommandOutcome.valid?` / test assertion (~75 ms compile, ~100
  rebuilds). Caching the JSV root in persistent_term cut
  `command_engine_test.exs` from **44.7 s to 23.0 s**. Full `core-tests.sh`
  after that cache plus the nightly tags: **200.8 s (64.8 s async, 136.0 s
  sync)** vs ~244 s / 174 s sync on main. Remaining serial is MCP stdio/source
  and leftover dispatch, not schema compilation.
- `git push --no-verify` skips `.githooks/pre-push` (confirmed: dry-run
  returned in 5 s). `git push --dry-run` still runs the hook.
- Do not overlap the suite with Dialyzer, release, or the launcher on
  pre-push. The remaining win is ~1s and the flake cost is documented.
- Do not change StreamData's `CI=1` 300-run setting for local push. Five
  properties.
- Do not regenerate `priv/semantic_build_projection.json` as part of this work.

## Slices, cheapest first

### 1. Scope git pre-commit format and credo to staged files — done

Implemented in this branch: `.githooks/pre-commit` passes sorted staged
`.ex`/`.exs` paths (Viewer-relative under `ptc_viewer/`) to `mix format` and
`mix credo`. Compile stays unscoped. Covered by `test/githooks/pre_commit_test.exs`.

### 2. Mark the ten accidentally serial Lisp modules `async: true` — done

The ten `use ExUnit.Case` Lisp modules now declare `async: true`.

### 3. Stop paying for `mix precommit` and pre-push back to back — done

Policy A is in `AGENTS.md` and `.githooks/README.md`: `mix precommit` keeps
quality + nested fetch and drops the full suite, Viewer, launcher package,
and release. Push stays the CI-equivalent gate. Dialyzer and ExDoc remain
on push.

### 4. Give `mix precommit` the same concurrent lanes as pre-push

Superseded by slice 3. `mix precommit` no longer runs tests, Viewer, launcher,
or release, so overlapping those lanes there has nothing left to overlap.

### 5. Drop `mix clean` from `scripts/ci/launcher-package.sh` if evidence allows

The launcher alias already sets `elixir_make` `force_build`. `mix clean`
throws away the seeded `_build` on every `mix precommit` and forces a native
rebuild. A warm launcher `mix precommit` without clean is 31s; with clean it
is a from-scratch compile. The `mix clean` line is asserted in
`test/scripts/ci_gates_test.exs`, so removing it is a contract change. Prove
`force_build` still rebuilds the NIF, then delete the clean.

### 6. Shrink the duplication gate's 23s

Hex ExDNA 1.5.x has no `--cache`. The cache is tested only on the unreleased
candidate job (`PTC_EX_DNA_PATH`). When that cache ships, enable it for the
ordinary local gate. Until then, chaining `mix compile` out of
`duplication_gate.sh` (quality already compiled) saves one Mix boot, not 23s.

Optionally run ExDNA in parallel with credo after one compile: both are
read-mostly on a warm `_build/test`. Measure; do not assume.

### 7. Split oversized `async: false` modules

This is the only way to cut the 185s serial floor, and therefore the only way
to make **git push** substantially faster. Start with modules that mix
pure unit tests with a few global-state cases:

- `command_engine_test.exs` — done: 153 tests `async: true`; 13 global-state
  cases in `command_engine_global_state_test.exs` (`async: false`); helpers
  in `test/support/command_engine_fixtures.ex`
- `mcp_source_test.exs` (52)
- `ptc_repl_test.exs` (54 mix-task tests; many may have to stay serial)
- `provider_active_session_test.exs` (41)
- `host_installation_test.exs` (34)

Move cases that do not call `File.cd`, `Application.put_env`, or
`System.put_env` into `async: true` modules. Leave a thin serial sibling for
the rest. Do not invent a wrapper that still mutates VM-global state from
async tests.

Re-measure `mix test` wall and the `async`/`sync` split after each split.
Stop when the serial floor is no longer the majority of suite wall, or when
the remaining serial tests are all genuinely global.

### 8. Small quality-script hygiene

`scripts/ci/core-quality.sh` boots Mix seven times; `duplication_gate.sh`
boots it twice more. `mix do compile --warnings-as-errors + format
--check-formatted + credo --strict + xref graph …` is already 13s including
credo. Chaining the cheap `ptc.*` checks into the same invocation saves a few
seconds, not a minute. Worth doing while touching the script; not a slice on
its own.

## Acceptance

A slice is done when:

- the measured warm time for the gate it claims to change is recorded in the
  PR, against the numbers above;
- `scripts/ci/core-tests.sh` still sets `CI=1` and does not reduce scheduler
  count;
- GitHub Actions still calls the same per-concern scripts (no second
  implementation of a gate);
- independent review of hook or CI-script changes follows
  `docs/maintainers/coding-agent-review.md`.

Delete this plan when the chosen slices have landed and the durable contract
(what each gate runs) lives in `.githooks/README.md` and `AGENTS.md`.
