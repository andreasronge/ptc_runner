# Pre-Push Performance — Phased Plan

## Status

**Active plan, executed on branch `perf/pre-push-bottlenecks` in
worktree `ptc_runner_perf`.** Each non-trivial phase is committed
independently; each is gated by a `codex review` pass before the next
phase starts. Phases can be discarded individually if codex flags
issues that aren't worth fixing.

Started: 2026-05-09. Branch base: `main` at `ab75ab9`.

**Revision (2026-05-09, post-codex):** original plan reviewed by
codex against actual repo state. Codex flagged 13 issues. All
incorporated:
- Baseline counts corrected (5 of 30 sync files are integration-only
  and excluded by default).
- Phase order changed to put the conservative hook gate first; it's
  the highest leverage and lowest implementation risk *if* made
  conservative enough.
- Phase 2 mechanism corrected (`Port.open` with `command: "mix"`,
  not `System.cmd("mix")`).
- Phase 4 docs-only gate redesigned with allow-list + worktree-clean
  check (README.md and docs/ptc-lisp-specification.md are read by
  tests; the original regex would have skipped tests for edits that
  do break them).
- Acceptance criteria tightened across the board.
- Phase 0 added for unrelated cleanup codex spotted.
- Plan now says "current pre-push gate," not "full suite" — current
  hook excludes `:clojure`, `:integration`, `:real_upstream` tags.

## Goal

Reduce `git push origin main` wallclock from the current ~53 s while
**preserving the safety guarantees of the current pre-push gate**.
Out of scope: dropping safety (`--no-verify`, removing tests or
dialyzer, lowering coverage).

Note: "current pre-push gate" ≠ "full suite." The hook runs
`mix test --exclude clojure`, and `mcp_server/test/test_helper.exs`
further excludes `:integration` and `:real_upstream` tags. Anything
new the plan introduces must compose with that exclusion model, not
fight it.

## Baseline (measured 2026-05-09)

| Stage | Time | % | Notes |
|---|---|---|---|
| `mcp_server` test suite (default exclusions) | **23.3 s** | **44%** | Biggest item |
| Root `:ptc_runner` dialyzer (warm PLT) | 11.9 s | 22% | |
| Root `:ptc_runner` test suite | 8.7 s | 16% | 4,745 tests, healthy |
| `mcp_server` dialyzer (warm PLT) | 3.6 s | 7% | |
| `mix` startup × 5 + shell | ~5 s | 9% | Fixed |
| `ptc_viewer` tests | 0.1 s | <1% | Negligible |

Test-file async distribution in `mcp_server/test/`:

- 44 `use ExUnit.Case` modules total.
- **30** declare `async: false`, **14** declare `async: true`.
- **5 of the 30 sync files live under `mcp_server/test/integration/`**
  and are excluded from the default test run by
  `mcp_server/test/test_helper.exs:14`. So the **default-path
  opportunity is 25 sync files**, not 30.

Two structural facts drive the plan:

1. `mcp_server` has 25 default-path sync files vs 14 async — majority
   sync.
2. The recent pre-push run logged "Waiting for lock on the build
   directory (held by process 58521)" — tail-latency cliff inside the
   suite.

## Sequencing rationale

Phases run smallest-leverage-loss-on-failure first:

| # | Phase | Why this order |
|---|---|---|
| 0 | Drop unused test helpers | Pure cleanup unrelated to perf, but codex flagged it. Trivial. |
| 1 | Conservative hook tracking + docs-only gate | Highest leverage for the recent docs-heavy commit pattern, low test-coverage risk *if* implemented conservatively. |
| 2 | Flip safe `async: false` files in `mcp_server/test/` | Real perf win, low architectural risk if isolation is documented per file. |
| 3 | Eliminate `mix run`-via-`Port.open` from default test paths | Removes lock-contention cliff. Surgical refactor. |
| 4 | Pool upstream subprocess fixtures | Highest architectural risk — runs last so failure here is contained. |

Phase 0 is trivial and goes in without codex review. Phases 1–4 each
get codex review before the next phase starts. Failed codex review →
fixup commit on the same phase, re-review, repeat until pass.

## Phase 0 — Drop unused test helpers

**Trivial cleanup, no codex review needed.**

`mcp_server/test/ptc_runner_mcp/upstream_supervisor_phase21_test.exs`
defines `await_connection!/3` and `do_await_connection/3` (lines 289
and 294) that are never called — dialyzer warns on both. Either
remove them or wire them into the test that actually needs polling.
Default action: remove. If a test surfaces that needs polling
later, it can re-add.

**Acceptance:** dialyzer warnings disappear; suite still passes.

## Phase 1 — Conservative hook tracking + docs-only short-circuit

**Hypothesis:** for the recent docs-heavy commit pattern, full
test+dialyzer per push is wasted work. A conservative
allow-list-based docs-only gate can drop pure-docs pushes from
~53 s to <2 s without compromising safety.

**Constraints surfaced by codex review:**

1. The current hook is at `.git/hooks/pre-push` (in the *main* repo's
   `.git`, not the worktree's). `.git` in a worktree is a *file*
   pointing at the linked `.git/worktrees/<name>` dir, not a
   directory. Hook moves must use
   `git rev-parse --git-path hooks/pre-push` or the resolved hook
   path, not literal paths.
2. Several markdown files are read by tests:
   - `README.md` is doctested by `test/readme_test.exs`.
   - `docs/ptc-lisp-specification.md` is read by
     `test/ptc_runner/lisp/spec_validator_test.exs` and by
     `lib/ptc_runner/lisp/spec_validator.ex`.
   - `mcp_server/README.md` is doctested in its own `:ptc_runner_mcp`
     project.
   - Other `*.md` files under `docs/`, `Plans/`, `mcp_server/`,
     `ptc_viewer/` may also be referenced.
3. The hook runs `mix test` against the **working tree**, not the
   committed bytes. A docs-only short-circuit must verify
   working-tree + index are clean (or only contain docs-allowed
   paths), not just inspect committed diffs.
4. Pre-push hooks receive ref updates on stdin (per
   `githooks(5)` — the `<local-ref> <local-sha> <remote-ref>
   <remote-sha>` lines). This is the correct way to enumerate
   pushed refs, not `@{u}` guesses (which fail on first push of a
   new branch).

**Approach:**

1. Move the hook to a tracked path: `.githooks/pre-push`. Make
   executable. Set `git config core.hooksPath .githooks` once per
   clone (document in README).
2. At the top of the hook, before any `mix` invocations:
   - Read pushed-ref tuples from stdin (per `githooks(5)`).
   - For each tuple: enumerate commits with
     `git rev-list <remote-sha>..<local-sha>` (or, if remote-sha is
     all-zeros, use `<local-sha>` against `origin/main` or the
     repo's default base).
   - Take the union of files changed across all those commits via
     `git diff-tree -r --name-only --no-commit-id`.
   - Also enumerate dirty paths in the worktree:
     `git status --porcelain --untracked-files=normal | awk '{print $2}'`.
   - Combine both sets.
3. Define a strict **docs-only allow-list** (paths that are *not*
   read by tests):
   - `^Plans/.*\.md$`
   - `^CHANGELOG\.md$`
   - `^.*\.txt$` (license, etc.)
   - `^\.gitignore$`
   - `^\.githooks/README\.md$` (the hook setup README, if added)
   Anything else — including `README.md`, `docs/**/*.md`,
   `mcp_server/README.md`, `mcp_server/docs/**/*.md` — falls through
   to the full gate.
4. If every file in the combined set matches the allow-list:
   print `📝 Docs-only push, skipping test/dialyzer gate (override:
   FORCE_FULL_PRE_PUSH=1)` and exit 0.
5. Otherwise: run the existing per-project loop unchanged.
6. Honor `FORCE_FULL_PRE_PUSH=1` env var: skip the short-circuit
   even when the allow-list matches. Documented inline.

**Acceptance:**

- Push of a `Plans/*.md`-only commit completes in <2 s.
- Push touching `README.md`, `docs/ptc-lisp-specification.md`, or
  `lib/**/*.ex` runs the full existing gate.
- Push with allow-listed commits but a dirty worktree containing a
  non-allow-listed path runs the full existing gate.
- `FORCE_FULL_PRE_PUSH=1 git push` always runs the full gate.
- Once-per-clone setup (`git config core.hooksPath .githooks`)
  documented in README and verifiable via
  `git config --get core.hooksPath`.

**Risk:**

- Docs-only allow-list misses a file that *is* test-consumed → tests
  silently skipped on edits that break them. Mitigation: explicit
  allow-list (not deny-list); CI on push (separate from the local
  hook) catches anything the local hook misses.
- Hook-path resolution wrong on a worktree → gate doesn't fire.
  Mitigation: shipping the hook as a tracked file under `.githooks/`
  + `core.hooksPath` is the standard remediation; tested by running
  the hook from this worktree as part of acceptance.

**Estimated impact:** ~50 s saved on docs-only pushes. Non-docs
pushes unchanged.

## Phase 2 — Flip safe `async: false` files in `mcp_server/test/`

**Hypothesis:** A material fraction of the 25 default-path sync
files in `mcp_server/test/` are sync defensively, not because the
tests genuinely conflict on shared state.

**Approach:**

1. Enumerate every `async: false` file in `mcp_server/test/`
   (excluding the 5 integration files — they're irrelevant to the
   default-path baseline).
2. For each file, classify the reason for sync. Real reasons:
   - Mutates `Application.put_env/3` for `:ptc_runner_mcp` config
     (e.g., `catalog_test.exs`, `log_test.exs`,
     `trace_config_test.exs`).
   - Registers globally-named processes outside the per-test
     `Stdio.Names` Registry.
   - Touches singleton state in `Upstream.Registry` or shared
     `:persistent_term` keys.
   - Asserts on telemetry events with global handlers and no
     per-test-pid filter.
3. **Per-file decision recorded inline** as a comment near the
   `use ExUnit.Case` line, citing the specific shared-state
   reference. Files with no real reason flip to `async: true`.
4. Verify acceptance below before moving on.

**Acceptance:**

- `mix test mcp_server/test/ --seed 0 --seed 1 --seed 2 … --seed 24`
  (25 distinct seeds, scripted) all pass green. Catches scheduler
  and ordering races the original "5× same seed" criterion missed.
- `rg 'async:\s*false' mcp_server/test/ -l | wc -l` decreases
  measurably (target: at least 8 files flipped).
- For every file *not* flipped, a one-line comment explains why
  sync is required (specific shared-state reference). No file is
  left as `async: false` without a recorded reason.
- mcp_server suite wallclock decreases by ≥3 s on a 20-core box.

**Risk:** New flakes from races previously masked by serialization.
Mitigation: 25-seed sweep is much stronger than 5× same-seed; any
file that flakes flips back with the failure mode recorded.

**Estimated impact:** mcp_server suite from 23 s → ~15–17 s.

## Phase 3 — Eliminate `mix`-via-`Port.open` from default test paths

**Hypothesis:** `mcp_server` mock-server tests open ports with
`command: "mix"` and `args: ["run", "--no-start", "--no-compile",
mock_path, …]`. Each such port spawn invokes the elixir/mix
launcher *and competes with the test runner's own build lock*. The
"Waiting for lock on the build directory" log line in the recent
pre-push run was caused by this pattern, not by `System.cmd("mix")`.

**Concrete sites** (verified by codex on actual repo state):

- `mcp_server/test/ptc_runner_mcp/upstream_stdio_phase1b_test.exs:40`
- `mcp_server/test/ptc_runner_mcp/behaviour_conformance_test.exs:73`
- `mcp_server/test/ptc_runner_mcp/application_phase1b_test.exs:64`
- The wrapper shell script at
  `mcp_server/test/ptc_runner_mcp/upstream_stdio_phase1b_test.exs:734`

The mock server is `mcp_server/test/support/mock_server.exs:56`,
which uses `Jason.encode!` — that's why it needs `mix run` for dep
loading. Naively replacing it with a static escript is *not* trivial;
deps must be available in the spawned interpreter.

**Approach (options, pick during execution):**

A. **Pre-compile mock_server to escript with deps bundled.** Static
   artifact, no `mix run` needed. Spawn cost drops to a single
   exec. Build the escript via a `mix.exs` task that runs once at
   suite startup or as a `setup_all`.
B. **Replace `mix run`-port spawn with a Burrito-style standalone
   release** if deps are heavy. Bigger change; probably overkill.
C. **Move tests that genuinely need a real subprocess to
   `:integration` tag**, excluded from the default path. Trade-off:
   default path no longer covers stdio-protocol behaviors against a
   real subprocess. Probably unacceptable; flag if it's the only
   viable path.

Default plan: option A unless something prevents it.

**Acceptance:**

- `rg 'command:\s*"mix"' mcp_server/test mcp_server/lib`
  returns zero hits in default-path test files (integration files
  may keep them).
- `rg 'exec mix' mcp_server/test mcp_server/lib` similarly clean.
- The "Waiting for lock on the build directory" warning does not
  appear across 10 consecutive `(cd mcp_server && mix test)` runs
  with random seeds.
- Behavioral coverage preserved: every test that previously launched
  a `mix run` mock now launches the precompiled artifact and still
  exercises the stdio handshake / tools/list / call paths it
  exercised before. Verified by inspecting the test diff
  before/after.
- `mcp_server` suite wallclock drops further (estimated 2–4 s).

**Risk:** Compiled-mock artifact diverges from `mix run` behavior
in subtle ways (env loading, cwd, code path). Mitigation: same
mock_server source, just compiled — behavior should match. Stress:
run the suite 10× post-change with random seeds before declaring
done.

**Estimated impact:** mcp_server suite from ~15–17 s → ~13–15 s,
plus removal of the lock-contention tail-latency cliff.

## Phase 4 — Pool upstream subprocess fixtures (architectural)

**Highest risk; runs last so failure is contained.**

**Hypothesis:** Many `mcp_server` tests spawn their own upstream
stdio subprocesses individually (visible in run logs as unique
names like `backoff-via-stdio-1641`, `call-crash-1800`,
`parent-exit-6914`). Each spawn pays binary load + handshake +
`tools/list`. Pooling fixtures across `describe` blocks amortizes
the cost.

**Invariants the per-test spawn pattern protects** (named explicitly,
per codex):

1. **Cached `tools/list` state** — each upstream caches its tools
   on first call; tests asserting on cache miss / refresh need a
   fresh process.
2. **Backoff timer state** — reconnect/backoff tests assert on
   timing windows that depend on a clean clock.
3. **Parent-exit ordering** — tests like `parent-exit-6914`
   verify that the upstream port closes when its parent BEAM
   process dies. Pooled fixtures break this.
4. **Crash-recovery behavior** — `call-crash-1800` asserts on
   restart semantics; pool can't share a crashed process.
5. **Env-driven mock behavior** — `application_phase1b_test.exs`
   spawns mocks with per-test env vars (`MOCK_PROBE_PATH`, etc.).
   Pool would have to reset env per checkout, which the mock
   doesn't support.
6. **Registry name uniqueness** — `Stdio.Names` Registry holds
   concurrent instances by unique name. Pool would need a
   reservation protocol.
7. **Teardown ordering** — `on_exit` callbacks assume per-test
   process; pool must keep this invariant or migrate tests to
   `setup_all` teardown.

**Approach:**

1. Inventory upstream-spawning tests. Group by upstream behavior
   needed: echo, slow, big, crash, parent-exit, env-driven,
   backoff.
2. **Tests in groups 3–5 (parent-exit, crash, env-driven) keep
   per-test spawn — non-negotiable.**
3. **Tests in groups 1–2 (echo, slow) and 6 (clean backoff
   start) are candidates for pooling**, *if* a per-checkout state
   reset hook is added to the mock server (separate small
   refactor).
4. Build a `setup_all` fixture for the poolable groups that spawns
   one upstream per `describe` and registers tests against it via
   per-test alias.
5. Verify isolation. The plan does not claim "passes under both
   regimes" — the pooled fixtures *replace* per-test spawn for the
   eligible groups. The criterion is: pool-eligible tests still
   assert correctly when run in arbitrary order.

**Acceptance:**

- Inventory document committed to `Plans/` listing every upstream
  spawn site, classification, and pool-vs-per-test decision with
  reason.
- Pool-eligible tests pass under 25-seed sweep (same protocol as
  Phase 2).
- Suite still passes when each pool-eligible `describe` is run
  alone (`mix test path/to/file.exs:LINE`).
- mcp_server suite wallclock drops by another ≥3 s, or this phase
  is reverted (it's the riskiest and not worth the architectural
  complexity for a marginal win).

**Risk:** Highest of the four. Pooled fixtures hide subtle
isolation bugs that only surface under specific ordering. Codex
review for this phase is the most important — should explicitly
challenge each invariant claim.

**Estimated impact:** Hard to predict. Plausibly 3–5 s further
savings; might be 1–2 s if most tests genuinely need per-test
spawn (groups 3–5 may dominate).

## Codex review gating

After each non-trivial phase commit:

1. Run `codex review` against the phase commit.
2. **`[P1]` findings → fixup commit on the same phase, re-review,
   repeat until pass.** This is the hard gate.
3. **`[P2]` findings → judgment call.** Fix if I agree, document
   reasoning if I don't.
4. Move to next phase only after `[P1]`-clean.
5. The plan itself is also subject to review when changed
   non-trivially. The original plan went through one review
   (this revision is the result). Any future plan revision that
   changes phase scope, acceptance criteria, or sequencing gets
   re-reviewed.

Phase 0 is trivial cleanup — skipped review per the user's "unless
trivial" carve-out.

## Merge story

When all phases land and review-pass:

1. Squash phase commits into per-phase clean commits (one per
   phase, no fixup churn in history).
2. Worktree handed back to the user. They merge / fast-forward to
   `main` when ready, or push the branch and review on GitHub if
   they prefer that flow).

This document is the source of truth for the work; commit-message
bodies should reference the phase number rather than re-explaining
the rationale.
