# Faster git hooks and `mix precommit`

**Status:** active; slices 1 and 2 implemented. Measurements from a warm
worktree on 2026-08-18 (Elixir on a 10-scheduler Mac, HEAD `d9a814b0`).

The three local gates are easy to conflate, and they do not cost the same:

| Gate | When | What it runs | Warm wall |
| --- | --- | --- | --- |
| `.githooks/pre-commit` | `git commit` | Staged-project format, compile, credo; scoped tests with `--exclude slow` | **13s** for static checks (target `<10s`) |
| `mix precommit` | agents, before every commit | Nested fetch, quality, full core tests, Viewer, launcher package, core release | **~7.7 min** serial |
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

`mix precommit` is different. It still runs quality, tests, Viewer, launcher,
and release **back to back**. The same lane idea the push hook already has
would cut it from ~7.7 min to about **5.1 min** (`max(quality+tests, release)`),
with tests overlapping only the last ~70s of release (mostly the async
portion of the suite). That is the one structural overlap that still has a
large payoff.

## The expensive double run

`AGENTS.md` asks for `mix precommit` before every commit and a full pre-push
on `git push`. An agent that follows both pays ~7.7 min then ~6.8 min, and
repeats tests, quality, Viewer, and release. That duplicated 15-minute loop
is larger than any remaining overlap inside a single gate.

The git pre-commit hook is already the fast commit path. `mix precommit` is a
third, almost-full CI.

## Serial tests, not Mix boots, dominate

- 250 files / 5541 tests are `async: true`.
- 59 files / 850 tests are `async: false` on purpose.
- **10 Lisp files / 523 tests** use `use ExUnit.Case` with no `async:` option,
  so they are serial by Elixir default. They are pure unit modules
  (`runtime_arithmetic`, `signature/coercion`, `spec_validator`, …) with no
  `Application.put_env`, `System.put_env`, or `File.cd`. This looks accidental.

Largest intentional serial module: `test/ptc_runner/kernel/command_engine_test.exs`
(159 tests, 266 KB). A handful of cases need `Application.put_env` / `File.cd`;
the rest sit in the same serial queue because they share the module.

## What not to do

- Do not lower ExUnit `max_cases` or add `--trace` / `--slowest` to make a
  gate look faster. `--trace` pins `--max-cases` to 1 (measured 259s on CI
  when that happened).
- Do not exclude `:slow` from `mix precommit`, pre-push, or CI. That tag exists
  only for the git pre-commit hook; excluding it globally dropped correctness
  tests from every PR to save 14s.
- Do not tag more tests `:nightly` to shrink the push suite. `:nightly` means
  "unverified on pull requests".
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

### 3. Stop paying for `mix precommit` and pre-push back to back

Pick one policy and write it in `AGENTS.md` plus `.githooks/README.md`:

- **A (recommended for agents):** `mix precommit` keeps quality + nested
  fetch, and drops the full suite, Viewer, launcher package, and release.
  Those already run on push. Commit cost falls from ~7.7 min to ~1 min.
  Push stays the CI-equivalent gate.
- **B:** Keep `mix precommit` comprehensive, and teach agents not to run it
  immediately before `git push`. Weaker, because the instruction is easy to
  ignore.
- **C:** Stamp file: pre-push skips a script whose digest and HEAD match a
  successful `mix precommit`. More machinery, easy to get wrong with dirty
  trees.

Do not silently drop Dialyzer or docs from push. Those are the parts
`mix precommit` already omits.

### 4. Give `mix precommit` the same concurrent lanes as pre-push

If slice 3 is not taken, extract the lane helper from `.githooks/pre-push`
into a repository script both entry points call:

- lane A: quality then tests (`_build/test`, shared Mix lock)
- lane B: core release (`_build/prod`)
- lane C: Viewer
- lane D: launcher package

Expected warm wall ≈ `max(302, 121)` ≈ **5.1 min** vs 7.7 min. Tests overlap
only the tail of release, after quality, during mostly-async work. Keep
`PTC_PRE_PUSH_SERIAL=1` as the escape hatch. GitHub Actions is already
parallel jobs and must keep calling the individual scripts.

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

- `command_engine_test.exs` (159 tests)
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
