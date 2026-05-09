# Pre-Push Performance — Phased Plan

## Status

**Active plan, executed on branch `perf/pre-push-bottlenecks` in
worktree `../ptc_runner_perf`.** Each phase is committed
independently; each phase is gated by a `codex review` pass before
the next phase starts. Phases can be discarded individually if codex
flags issues that aren't worth fixing.

Started: 2026-05-09. Branch base: `main` at `ab75ab9`.

## Goal

Reduce `git push origin main` wallclock from the current ~53 s while
keeping the safety guarantees of the current pre-push hook (full test
suite + dialyzer per project). The current breakdown was measured in
the previous session:

| Stage | Time | % | Notes |
|---|---|---|---|
| `mcp_server` test suite | **23.3 s** | **44%** | Biggest single item |
| Root `:ptc_runner` dialyzer (warm PLT) | 11.9 s | 22% | |
| Root `:ptc_runner` test suite | 8.7 s | 16% | 4,745 tests, healthy |
| `mcp_server` dialyzer (warm PLT) | 3.6 s | 7% | |
| `mix` startup × 5 + shell | ~5 s | 9% | Fixed |
| `ptc_viewer` tests | 0.1 s | <1% | Negligible |

Two structural facts drive the plan:

1. `mcp_server` has **30 sync test files vs 14 async** — majority sync.
2. The recent pre-push run logged "Waiting for lock on the build
   directory (held by process 58521)" — tail-latency cliff inside the
   suite.

Out of scope here: dropping safety (skipping tests, dialyzer-off,
`--no-verify`). Every phase preserves the current correctness gate
and is reversible.

## Phase 1 — Audit and flip safe `async: false` files in `mcp_server`

**Hypothesis:** A meaningful fraction of the 30 sync files in
`mcp_server/test/` are sync defensively, not because the tests
genuinely conflict on shared state. Flipping the safe ones to
`async: true` lets ExUnit parallelize them up to `max_cases: 20`.

**Approach:**

1. Enumerate every `async: false` file in `mcp_server/test/`.
2. For each: classify the reason for sync. Common signals that
   require sync:
   - mutates `Application.put_env/3` for `:ptc_runner_mcp` config.
   - registers globally-named processes (`:via {Registry, …}` is
     fine; bare-name registration is not).
   - touches singleton stdio state (`Stdio.Names`, `Upstream.Registry`).
   - asserts on telemetry events with global handlers.
3. For each file with no real reason, flip to `async: true`.
4. Run `(cd mcp_server && mix test)` 5× back-to-back to catch races
   that only surface under load. Anything that flakes flips back.
5. Time the suite before/after to confirm the win.

**Acceptance:** mcp_server suite passes 5× consecutively under
async, with measurable wall-clock reduction.

**Risk:** New flakes from races that were previously masked by
serialization. Mitigation: 5× repeat and revert any file that
flakes. Codex review pass acts as the final gate.

**Estimated impact:** mcp_server suite from 23 s → ~12–15 s on a
20-core box. ~8–11 s saved.

## Phase 2 — Hunt and remove `mix` build-lock contention

**Hypothesis:** A specific test (or test setup) in `mcp_server/`
shells out to `mix` (or to a fixture that itself runs `mix`),
competing with the test runner's own build lock. The "Waiting for
lock on the build directory" log line proves at least one such call
exists. When it fires, it adds tail-latency that is invisible in the
average but visible in the P99.

**Approach:**

1. Grep `mcp_server/test/` for `System.cmd("mix"`, `Mix.Task.run`,
   `Mix.Shell`, and any wrapper calling `mix release` /
   `mix compile`.
2. Identify the call site(s).
3. For each: replace the spawn with one of —
   - a pre-built artifact resolved via test fixture path, or
   - a direct module call (no subprocess), or
   - a guard that skips the lock-contending path entirely when
     running under `MIX_ENV=test`.
4. Re-run the suite repeatedly to confirm the lock-wait warning
   disappears.

**Acceptance:** No "Waiting for lock on the build directory" logs
across 10× consecutive `mix test` runs.

**Risk:** Low — the call is almost certainly an over-engineered
fixture. Replacing it with a static artifact is straightforward.

**Estimated impact:** Removes a 1–60 s tail-latency cliff. Average
case may not move; worst case improves dramatically.

## Phase 3 — Pool upstream subprocess fixtures in `mcp_server`

**Hypothesis:** Many `mcp_server` tests spawn their own upstream
stdio subprocesses individually (visible in the run as
`{:upstream_exited, …}` for unique names like `backoff-via-stdio-1641`,
`call-crash-1800`, `parent-exit-6914`). Each spawn pays
100–500 ms for binary load, handshake, and `tools/list`. Pooling /
sharing fixtures across tests in a `describe` block amortizes the
cost.

**Approach:**

1. Inventory upstream-spawning tests. Group by what kind of upstream
   they need (echo, slow, big, crashing).
2. For each kind: build a `setup_all` fixture that spawns one
   upstream and registers it with a per-test alias. Tests that
   genuinely need a fresh process (parent-exit, crash recovery,
   handshake-timeout) keep their own spawn.
3. Verify isolation guarantees — pooled upstreams must reset state
   between tests, or tests must not depend on cross-test isolation.
4. Re-run suite, time the delta.

**Acceptance:** Suite passes 5× under both pooled and per-test
regimes; pooled-fixture tests don't see cross-test contamination.

**Risk:** Highest of the four phases. Pooled fixtures hide subtle
isolation bugs. Codex review here is most important.

**Estimated impact:** Hard to predict — depends on how many tests
spawn vs. how many can share. Plausible 5–10 s further off
mcp_server suite, but it could also be 1–2 s if most tests already
share where they can.

## Phase 4 — Track the pre-push hook + docs-only gate

**Hypothesis:** The hook currently lives at `.git/hooks/pre-push`,
which is not under version control. That makes hook changes
unreviewable, unshareable, and undiscoverable. Tracking it (via
`core.hooksPath`) plus adding a docs-only gate would skip the
~15.5 s combined dialyzer cost and ~32 s combined test cost when no
`lib/`, `mix.exs`, `mix.lock`, or `config/` files changed.

**Approach:**

1. Move `.git/hooks/pre-push` into a tracked location:
   `.githooks/pre-push`, `chmod +x`.
2. Set `git config core.hooksPath .githooks` and document this in
   the README (one-time per-clone setup).
3. Add a path-aware short-circuit at the top of the hook:
   - Compute the diff between the local ref and its upstream
     (`git diff --name-only @{u}..HEAD`, or fall back to
     `origin/main..HEAD` if no upstream).
   - If every file matches `^(Plans/.*\.md|docs/.*\.md|.*README.*\.md|CHANGELOG\.md)$`,
     print "📝 Docs-only push, skipping test/dialyzer gate" and exit 0.
4. Document the escape hatch (env var `FORCE_FULL_PRE_PUSH=1`) in
   the hook itself for the rare docs-only push that touches
   doctest-bearing files.

**Acceptance:** Docs-only push completes in <2 s; non-docs push
runs the full suite as before; `FORCE_FULL_PRE_PUSH=1` overrides.

**Risk:** Low. The gate is explicitly path-conservative — anything
that could touch code falls through to the full suite.

**Estimated impact:** Docs-only pushes drop from ~53 s to ~1–2 s.
Non-docs pushes unchanged. This is the highest impact-to-effort
ratio of the four phases for the workflow we just exercised.

## Sequencing and codex review gates

Run order: **1 → 2 → 3 → 4**, smallest-risk last because tracking
the hook is purely additive (no test-coverage risk) but it does
modify per-clone setup, so I'd rather not bundle it with any phase
that could be reverted independently.

After each phase:

1. Commit the phase as a single commit with conventional message
   (`perf(mcp_test): …`, `test(mcp): de-flake build-lock`, etc.).
2. Invoke `codex review` against that commit's diff.
3. If codex flags issues: fix in a fixup commit on the same phase,
   re-review, repeat until pass. (Squash before merging back to
   main.)
4. Move to next phase only after codex pass.

If a phase fails review and isn't worth fixing, the branch can drop
that phase via `git rebase -i` and the remaining phases stand on
their own.

## Merge story

When all phases land and review-pass:

1. Squash phase commits into per-phase clean commits (one per
   phase, not many fixups).
2. Hand the worktree back to the user. They merge / fast-forward to
   main when ready (or push the branch and review on GitHub if they
   prefer that flow).

This document is the source of truth for the work; commit-message
bodies should reference the phase number rather than re-explaining
the rationale.
