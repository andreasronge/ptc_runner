# Pre-Push Performance — Phased Plan

## Status

**Active plan, executed on branch `perf/pre-push-bottlenecks` in
worktree `ptc_runner_perf`.** Each non-trivial phase is committed
independently; each is gated by a `codex review` pass before the next
phase starts. Phases can be discarded individually if codex flags
issues that aren't worth fixing.

Started: 2026-05-09. Branch base: `main` at `ab75ab9`.

**Revision 1 (2026-05-09, post-codex):** original plan reviewed by
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

**Revision 2 (2026-05-09, post-codex re-review):** revision 1
re-reviewed by codex; 9 further issues found. All addressed:
- Phase 1 dirty-path enumeration switched from `awk '{print $2}'`
  (broken on renames + paths with spaces) to `-z`-delimited
  porcelain v1 with rename-aware Python parser; both old and new
  paths of a rename go into the dirty set.
- Phase 1 `^.*\.txt$` allow-list pattern narrowed to exact
  `^LICENSES/MIT\.txt$` to avoid silently matching future
  `priv/**.txt` or `test/support/**.txt` fixtures.
- Phase 1 explicit deny list added with verified runtime-read
  paths: `priv/prompts/*.md`,
  `mcp_server/priv/{mcp_authoring_card,mcp_aggregator_authoring_card}.md`,
  plus the previously-listed README and docs.
- Phase 1 `mcp_server/README.md` doctested claim corrected — it
  isn't doctested today, kept conservatively denied.
- Phase 2 acceptance command rewritten as a `for` loop. Multiple
  `--seed` flags in one `mix test` command don't produce 25 runs.
- Phase 2 stress variant added with `--max-cases` × seed grid to
  catch scheduler-density races, not just ordering races.
- Phase 2 `async: false` count grep filters integration files.
- Phase 3 default approach pinned to compile-time artifact build
  (compiler entry or `mix.exs` alias on `test`). Building the
  escript inside `setup_all` would re-introduce mix/build-lock
  contention this phase exists to remove.
- Phase 3 acceptance grep broadened to catch
  `System.find_executable("mix")` and `exec mix` wrappers, not
  just `command: "mix"`.
- Phase 4 backoff tests removed from pooling candidates — backoff
  state is a per-test-spawn invariant; partially exempting it
  without a defined reset proof was incoherent.

**Revision 3 (2026-05-09, post-codex re-re-review):** revision 2
re-reviewed; 1× `[P1]` and 2× `[P2]` issues. All addressed:
- Phase 1 rename parser corrected: `status[0] in "RC"` → check both
  status columns. Porcelain v1 puts index status in column 0 and
  worktree status in column 1; renames can appear in either, and
  the previous parser missed unstaged-detected renames (` R`/` C`).
- Phase 1 markdown-reader inventory expanded with
  `lib/ptc_runner/prompt_loader.ex:11`, `usage-rules*.md` via
  `test/usage_rules_test.exs`, and an
  `lib/ptc_runner/lisp/registry.ex` `@external_resource`.
- Phase 1 explicit deny list now includes `usage-rules.md` and
  `usage-rules/*.md`.
- Phase 3 made explicit: `mcp_server/mix.exs` has no `compilers:`
  list and no `test` alias today. The plan now says creating one
  is part of the work and recommends the `test` alias path with a
  `Mix.Tasks.Compile.MockEscript` module as the default.

**Revision 4 (2026-05-09, post-execution + codex consult):**
Phase 2 hit a wall during execution and the plan needed a structural
reframe. Codex consulted on what to do next; this revision encodes
the response. Changes:
- **Old Phase 2 (async-flips) RETIRED.** Hypothesis was falsified
  during execution: of 25 default-path sync files, only 1 was safely
  flippable. Three other candidates exposed real failure modes
  under load (`stdio_test.exs` harness timeout, `stdio_lifecycle_test.exs`
  monitor race, `stdio_latin1_test.exs` aggravated the phase21
  flake). The other 21 files mutate `Application.put_env`, global
  registries, `:persistent_term`, or telemetry — sync for real
  reasons. The Phase 2 attempt is preserved in a stash; not
  shipping. Codex: "documentation debt masquerading as progress."
- **Old Phase 4 (subprocess fixture pooling) SHELVED.** Phase 2's
  lessons demonstrated the suite has real global-state sensitivity;
  pooling is invasive and likely to create hidden state coupling.
  Shelved unless Phase 3 measurements prove subprocess startup
  dominates and pooling is the only credible fix. Codex agreed.
- **New Phase 2: parallel subproject checks.** The current hook
  loops sequentially over root / `mcp_server` / `ptc_viewer`. Codex
  flagged this as "probably the next thing to measure" — if the
  three subprojects don't contend on build artifacts, parallel
  execution could shave ~10–15 s off code-touching pushes for free.
  Lower risk and higher leverage than the retired Phase 2.
- **Phase 3 conditional on re-profiling.** Original baseline (53 s)
  may not describe the decision problem after Phase 1 + new
  Phase 2 land. Re-profile code-touching pushes before deciding
  whether `mix run`-via-`Port.open` elimination is still worth it.
- **Pre-existing flake escalated.** Phase 2's investigation
  surfaced a flake in `upstream_supervisor_phase21_test.exs`
  "DynSup restart-intensity cascade" that exists on `main`
  (~1/8 runs on seed=24). Bit two of three recent pushes. Being
  fixed on a separate branch (`fix/phase21-cascade-flake`) and a
  separate PR; not part of this perf plan, but blocking confidence
  in any timing measurement until it lands.

## Status post-execution (2026-05-09)

| Phase | Status | Notes |
|---|---|---|
| 0 | ✅ Shipped | Commit `7cdca33`. |
| 1 | ✅ Shipped | Commits `144ef7a` (base) + `58cd523` (codex-fixup). PR #887. |
| Old 2 (async-flips) | ❌ Retired | Hypothesis falsified. Stashed, not shipped. |
| New 2 (parallel subprojects) | ❌ Aborted at Gate A | Median wins by 13.48 s, p95 wins ~37 s, but introduces a 50% sandbox-timeout flake rate on the 10-core baseline machine. See §"Phase 2 (new) outcome — ABORTED at Gate A". |
| 3 (mix-via-port) | ⏸ Conditional | Re-profile after new Phase 2 first. |
| Old 4 (pooling) | 🗄 Shelved | Phase 2 lessons make this not worth the risk. |
| Side: phase21 flake | 🔧 In flight | Separate branch + PR. |

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

## Sequencing rationale (post-Revision 4)

Phases run smallest-leverage-loss-on-failure first. Old Phase 2 and
old Phase 4 are retired/shelved per Revision 4; they remain in the
doc below for archival reference.

| # | Phase | Status | Why this order |
|---|---|---|---|
| 0 | Drop unused test helpers | ✅ Shipped | Pure cleanup. Trivial. |
| 1 | Tracked hook + docs-only short-circuit | ✅ Shipped | Highest leverage for docs-heavy pushes. Conservative implementation kept test-coverage risk low. |
| 2 (new) | Parallel subproject checks | ❌ Aborted | Gate A measurement: 13.48 s median win and a 37 s p95 *improvement*, but introduces a new sandbox-timeout flake class (5/10 parallel runs failed; 0/10 sequential failures from this class). Criterion #4 ("no new flakes") fails decisively. See §"Phase 2 (new) outcome — ABORTED at Gate A". |
| 3 | Eliminate `mix run`-via-`Port.open` | Conditional | Re-profile after new Phase 2 ships before deciding. |
| Old 2 | Flip async:false files | Retired | Hypothesis falsified. See §"Old Phase 2 (RETIRED)" below. |
| Old 4 | Pool subprocess fixtures | Shelved | Phase 2 lessons make this not worth the risk. See §"Old Phase 4 (SHELVED)" below. |

Phase 0 is trivial and went in without codex review. Phases 1, new
2, and 3 each get codex review before the next phase starts. Failed
codex review → fixup commit on the same phase, re-review, repeat
until pass.

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
2. Several markdown files are read at runtime or doctested. Verified
   by grepping for `File.read`/`File.read!`/`@external_resource`
   against `*.md` paths in the repo:
   - `README.md` is doctested by `test/readme_test.exs`.
   - `docs/ptc-lisp-specification.md` is read by
     `test/ptc_runner/lisp/spec_validator_test.exs:283`, by
     `lib/ptc_runner/lisp/spec_validator.ex:21`, and by
     `test/support/ptc_lisp_benchmark.ex:63`.
   - `priv/prompts/*.md` files are read at compile time via
     `@external_resource` chains in `lib/ptc_runner/prompts.ex:78`
     (multiple files; the canonical reader). The moduledoc example
     in `lib/ptc_runner/prompt_loader.ex:11` is illustrative, not
     a live read site.
   - `mcp_server/priv/mcp_authoring_card.md` and
     `mcp_server/priv/mcp_aggregator_authoring_card.md` are read by
     `mcp_server/lib/ptc_runner_mcp/tools.ex:50` and `:63` via
     `@external_resource`.
   - `usage-rules.md` and `usage-rules/*.md` are read by
     `test/usage_rules_test.exs:33`.
   - `mcp_server/README.md` and `ptc_viewer/README.md` are *not*
     verified doctested today, but are conservatively denied (cheap
     defense; they may be added to a doctest target later).
   - All other `*.md` files under `docs/`, `mcp_server/docs/`,
     `mcp_server/`, `ptc_viewer/` are conservatively denied.
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
   - Enumerate dirty paths in the worktree using `-z`-delimited
     porcelain output to handle paths with spaces, renames, and
     copies safely:
     ```bash
     git status --porcelain=v1 -z --untracked-files=normal |
       python3 -c '
     import sys
     buf = sys.stdin.buffer.read().split(b"\\0")
     i = 0
     while i < len(buf):
         entry = buf[i]
         if not entry:
             i += 1
             continue
         status = entry[:2].decode()
         path = entry[3:].decode()
         # Renames / copies. Porcelain v1 puts the index status in column 0
         # and the worktree status in column 1. Renames can appear in either
         # column ("R " for staged, " R" for unstaged-detected, "RR" for both).
         # When either column is R/C, the next NUL-record holds the old path.
         if status[0] in "RC" or status[1] in "RC":
             print(path)         # new path
             if i + 1 < len(buf):
                 print(buf[i + 1].decode())  # old path
             i += 2
         else:
             print(path)
             i += 1'
     ```
     Both old and new paths of a rename go into the dirty-set so a
     dirty rename `Plans/a.md → README.md` cannot evade the deny.
   - Combine the committed-diff set and the dirty set.
3. Define a strict **docs-only allow-list** (exact patterns, paths
   that are *not* read by tests, runtime code, or doctests):
   - `^Plans/.*\.md$`
   - `^CHANGELOG\.md$`
   - `^LICENSES/MIT\.txt$`
   - `^\.gitignore$`
   - `^\.githooks/README\.md$` (the hook setup README, if added)
   The previous draft used `^.*\.txt$` — too broad, would silently
   match future `priv/**.txt` or `test/support/**.txt` fixtures.
   Pin to the exact license path instead.

   **Explicit deny list** — verified read at runtime or doctested,
   *must* fall through to the full gate:
   - `^README\.md$` (doctested by `test/readme_test.exs`)
   - `^usage-rules\.md$`, `^usage-rules/.*\.md$` (read by
     `test/usage_rules_test.exs`)
   - `^docs/.*\.md$` (especially `docs/ptc-lisp-specification.md`)
   - `^priv/prompts/.*\.md$` (read by `lib/ptc_runner/prompts.ex`)
   - `^mcp_server/priv/.*\.md$` (read by
     `mcp_server/lib/ptc_runner_mcp/tools.ex`)
   - `^mcp_server/README\.md$`, `^mcp_server/docs/.*\.md$`
   - `^ptc_viewer/README\.md$`, `^ptc_viewer/docs/.*\.md$`
   - All `lib/**`, `test/**`, `mcp_server/lib/**`,
     `mcp_server/test/**`, `ptc_viewer/lib/**`,
     `ptc_viewer/test/**`, `mix.exs`, `mix.lock`, `config/**`,
     `priv/**` (anything not explicitly allow-listed).
   The hook should be allow-list-positive: every file in the
   combined set must match the allow-list, otherwise full gate.
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

## Phase 2 (new) — Parallel subproject checks

**Hypothesis:** the current hook loops sequentially over the three
Mix subprojects (`.`, `mcp_server`, `ptc_viewer`), running
`mix test` then `mix dialyzer` for each. Running them concurrently
should shave wallclock from any push that doesn't take the
docs-only short-circuit, which is now the common case for code
changes. Codex flagged this as "probably the next thing to measure"
after Phase 1.

### What the current hook does

In `.githooks/pre-push`, after the docs-only short-circuit:

```
for proj in . mcp_server ptc_viewer; do
  pushd "$proj"
  mix test --exclude clojure || exit 1
  mix dialyzer || exit 1
  popd
done
```

Sequential. Total ~32 s across the three subprojects in the current
baseline (8.7 + 23.3 + 0.1 for tests; 11.9 + 3.6 + 0 for dialyzer;
plus shell + mix-startup overhead).

### Approach

1. **Measure first, with a precisely specified harness.** Before
   touching the hook, write a scratch script that exactly mirrors the
   intended runtime shape:

   ```
   for proj in . mcp_server ptc_viewer; do
     (
       cd "$proj" && \
       mix test --exclude clojure && \
       if grep -qE '\{:dialyxir,' mix.exs; then mix dialyzer; fi
     ) &
   done
   wait
   ```

   Three background jobs, each doing test-then-(conditionally)-
   dialyzer sequentially **inside** the project. Not six
   fully-concurrent commands. The dialyzer step is gated on the
   presence of `:dialyxir` in the project's `mix.exs`, mirroring
   the current hook's `project_has_dep` check
   (`.githooks/pre-push:296`). `ptc_viewer/mix.exs` has no
   `:dialyxir` dep today, so the harness skips dialyzer there —
   exactly as the production hook does. Compare against the
   current sequential loop on the *same* machine, *same* load
   profile.

   Required preconditions for the measurement to be meaningful:
   - **Warm deps and PLT** for all three projects (`mix deps.compile`
     and `mix dialyzer --plt` run once per project before timing).
   - **Clean worktree** (no uncommitted changes touching tests,
     no stale `_build` partial-compile state).
   - **Phase21 flake fixed or excluded** from the timing test runs
     (`fix/phase21-cascade-flake` PR must land first, or the timing
     runs use `--exclude phase21_flake_tag`). Otherwise sporadic
     test failures contaminate the measurement.
   - **Quiet machine** — no other heavy tasks running during
     timing. Use `time` repeatedly (≥5 runs each side) and report
     median + p95.

   If concurrent isn't faster on this harness, abort the phase
   *before* refactoring the hook. Watch for these contention
   sources during measurement:
   - `_build` lock contention between projects (each has its own
     `_build/{dev,test}` — should be fine; verify with `lsof` or
     `fs_usage` while running).
   - Hex cache contention (`~/.hex/` — only on fresh clones).
   - CPU / scheduler saturation: 3 concurrent BEAM VMs can starve
     each other on small machines. Median win on a 20-core box
     might disappear on an 8-core box.
   - Shared `System.tmp_dir!()` filename collisions if any tests
     hardcode a path that collides across subprojects.
   - Tests that mutate OS env via `System.put_env/2` — concurrent
     mutation across BEAM VMs is fine (separate processes), but
     concurrent mutation *within* the same VM (e.g., async tests
     in the same project) was already a hazard. Confirm none cross
     the VM boundary.
   - Path-dep compile effects: if any of the three projects
     `path:` to another at build time, parallel `mix test` may
     trigger redundant or conflicting compile of the shared
     source.

2. **Decide whether to land based on a multi-criterion threshold,**
   not a rigid ≥5 s rule:
   - **Statistically repeatable positive median win** across the
     ≥5 timing runs. Single-shot wins don't count.
   - **No p95 regression.** If concurrent is faster on average
     but tail-latency increases (e.g., one project occasionally
     gets starved), the developer experience degrades.
   - **Either** ≥5 s median improvement, **or** trivial
     implementation (a 5-line refactor) with a stable smaller win.
   - **No new flakes** introduced — concurrent execution must not
     reveal a race that didn't exist sequentially.

   If all four hold: land. Otherwise abort and document the
   negative result so a future revision doesn't re-attempt this
   phase blindly.

3. **Refactor the hook to launch the three subproject loops as
   background jobs and `wait` for all to finish.** Capture each
   project's output to a per-project temp file via `mktemp`; clean
   up on exit via `trap`.

4. **Output semantics — decided.** The current hook streams full
   command output as it runs. The new flow can't preserve that
   without interleaving across projects. Choice (and rationale):
   - **On failure:** dump the failing project's full captured
     output, then any other failed projects' output, in
     project-list order. Match the current hook's failure
     verbosity.
   - **On success:** print only each project's `✅` summary lines
     (the same `Tests passed`, `Dialyzer passed` lines the
     sequential hook prints), in project-list order. Drop the
     verbose interleaved test output that's currently emitted.
   - **`PRE_PUSH_VERBOSE=1` env var** opts back into full output
     for debugging (dumps each project's full log even on success).

   The success-path log loss is the actual behavior change; flag
   it explicitly in the commit body and the README.

5. **Failure semantics — decided.** Pick "all-finish + report-all"
   over "first-failure-aborts-rest." Rationale: the developer
   fixing pre-push failures benefits more from seeing every
   project's failure in one cycle than from saving 10–20 s when
   the hook would have aborted early. Document the trade in the
   commit body. The exception: if a project's test run produces
   destructive side effects (writing to shared dirs, mutating
   OS-level state), abort early. None of the three projects do
   this currently; verify before relying on it.

6. **Match the current hook's project-list and dialyzer-skip
   semantics exactly.** The new hook must:
   - Process the same project list (`.`, `mcp_server`,
     `ptc_viewer`) in the same order.
   - Skip dialyzer for any project without `:dialyxir` declared
     (matches the current `project_has_dep` check).
   - Honor `FORCE_FULL_PRE_PUSH=1` and the docs-only short-circuit
     from Phase 1 (no regression on the docs-only path —
     verify by running the four Phase 1 acceptance cases against
     the new hook).
   - Exit non-zero on any project failure (preserve the existing
     contract).

7. **Update `.githooks/README.md`** with the new behavior, the
   `PRE_PUSH_VERBOSE=1` opt-in, and any per-project temp-file
   paths a developer might want to inspect during a failure.

### Acceptance

- **Multi-criterion landing threshold (per Approach #2):**
  - Statistically repeatable positive median win across ≥5 timing
    runs each (sequential and concurrent).
  - No p95 regression.
  - Either ≥5 s median improvement, or trivial implementation
    with a stable smaller win.
  - No new flakes introduced.
- **Output semantics — explicit:**
  - On failure: full captured output of every failed project,
    project-list order.
  - On success: per-project `✅` summary lines only, project-list
    order. Verbose stream available via `PRE_PUSH_VERBOSE=1`.
- **Multi-failure case works:** if both root and `mcp_server` fail,
  both failure outputs are printed (not just the first).
- **No false greens:** the hook still correctly exits non-zero on
  any subproject failure.
- **No race condition between concurrent `mix dialyzer` runs.** If
  one is detected (PLT corruption, lock errors), the phase aborts
  and the hook stays sequential. Verify by 25 consecutive runs of
  the new hook on a code-touching commit; any PLT lock error or
  inconsistent dialyzer result reverts the phase.
- **Project-list and dialyzer-skip semantics match the current
  hook exactly.** Verify by inspecting each project's output: if
  a project lacks `:dialyxir`, it must show `⏭️ Dialyzer not
  declared`, identical to today.
- **Phase 1 acceptance cases pass unchanged.** Re-run the four
  Phase 1 acceptance cases (docs-only, source-touch, dirty-tree,
  `FORCE_FULL_PRE_PUSH=1`) against the new hook. None should
  regress.
- **Worktree environment doc updated:** if the new flow needs any
  new dependency (`mktemp`, `wait`, `trap`), document any unusual
  portability gotchas (e.g., bash 3.2 on stock macOS).

### Risk

- **PLT contention** — three concurrent `mix dialyzer` runs may
  fight over the dialyxir PLT cache. Mitigation: per-project
  `_build` already gives each its own PLT; verify before
  refactoring.
- **CPU / scheduler saturation** — three concurrent BEAM VMs can
  starve each other on small machines. A median win on a
  20-core dev box might vanish on an 8-core CI machine or a
  contention-heavy laptop. Mitigation: measurement step runs on
  the typical target hardware before landing.
- **Output interleaving** — addressed by capturing per-project
  output to temp files and printing in deterministic order at the
  end. Verbose-on-success path requires `PRE_PUSH_VERBOSE=1`.
- **Loss of warning visibility on success** — current hook
  streams full output; new hook hides it on green. A regression
  in warning volume would be invisible until someone explicitly
  ran `PRE_PUSH_VERBOSE=1`. Document the trade in the commit body.
- **Failure-mode regression** — `all-run + report-all` is a
  behavior change vs `first-failure-aborts`. Document it in the
  commit body and README.
- **Shared `System.tmp_dir!()` collisions** — if any tests
  hardcode tmp paths that collide across subprojects, parallel
  runs might race. Each project's tests today appear to use
  per-test unique tmp dirs; verify by `rg -n 'tmp_dir!()'`
  before refactoring.
- **`System.put_env` cross-VM mutation** — irrelevant across BEAM
  VM boundaries (separate processes), but worth confirming none
  of the projects' tests assume cross-VM env state.
- **Path-dep compile cross-talk** — if any of the three projects
  declares another via `path:` and depends on its compiled
  artifacts, parallel `mix test` may trigger redundant or
  conflicting compile. Verify by inspecting each `mix.exs`'s
  `deps` list before refactoring.
- **Test-port contention** — the three subprojects might fight
  over fixed-port bindings if any tests use `Bandit` /
  `Cowboy` / similar with hardcoded ports. Phase 2's measurement
  step surfaces this before code lands.
- **Phase21 flake confounds the measurement.** Until the
  separate `fix/phase21-cascade-flake` PR lands or the test is
  tagged out of the timing runs, sporadic failures will skew
  median + p95 numbers. Sequence the measurement step *after*
  the flake fix.

### Estimated impact

If the test+dialyzer paths can run in parallel: code-touching push
wallclock drops from ~53 s to ~30–35 s. If only the test runs can
parallelize but dialyzer can't (PLT contention): smaller win,
maybe 5–8 s. If neither parallelizes cleanly: phase aborts before
landing.

This phase is the "measure twice, cut once" phase — the design
*depends* on the measurement step actually showing a win.

### Phase 2 (new) outcome — ABORTED at Gate A (2026-05-09)

**Result:** measurement was decisive; refactor not landed. Single commit
on `perf/phase2-parallel-subprojects` records this negative result and
the plan; the hook is unchanged.

**Hardware:** Apple M1 Pro, 10 cores (8 perf + 2 efficiency), 32 GB,
macOS 25.3.0. Erlang/OTP 28, Elixir 1.19.3. Worktree rebased onto
`origin/main` at `bd00dc5` so the phase21 cascade-flake fix is in.
Warm deps + warm PLT for all three projects before timing.

**Harness shape (exactly per plan §"Phase 2 (new)"):**

```
for proj in . mcp_server ptc_viewer; do
  ( cd "$proj" \
    && mix test --exclude clojure \
    && if grep -qE '\{:dialyxir,' mix.exs; then mix dialyzer; fi
  ) [ &  # parallel only ]
done
[ wait  # parallel only ]
```

stdout/stderr per project captured to side logs so failure-mode
diagnosis didn't pollute timing.

**Wallclock (10 alternating-then-isolated runs each side, contaminated
runs excluded from timing stats):**

| Variant | n (clean) | median | p95 | min | max | failure rate |
|---|---|---|---|---|---|---|
| Sequential | 9/10 | **57.93 s** | **86.83 s** | 53.87 s | 86.83 s | 1/10 (10%) |
| Concurrent | 5/10 | **44.45 s** | **49.50 s** | 37.97 s | 49.50 s | **5/10 (50%)** |

If only timing mattered: median wins by 13.48 s and p95 *improves*
by ~37 s (concurrent has tighter tail because no single project's
slow run cascades the others). Both clearly above the ≥5 s
threshold.

**But criterion #4 fails decisively.** Concurrent execution introduces
a new flake class that does not exist sequentially:

- Every parallel-run failure was in `root` (no failures in
  `mcp_server` or `ptc_viewer` across 10 parallel runs).
- Every failure was a `PtcRunner.Lisp.*` integration/runtime test
  asserting on `Sandbox.execute/3` with the **default 1000 ms
  wallclock budget**, failing as `MatchError` on
  `{:error, %Step{fail: %{reason: :timeout, message: "execution
  exceeded 1000ms limit"}}}`.
- Distinct tests fail on different runs — it's not a single brittle
  test, it's the whole class of `Sandbox`-budgeted assertions:
  `BenchmarkScenariosTest`, `FunctionOpsTest`, `TerminationTest`,
  `RuntimeInteropTest`, `EvalSetsTest`, `NameKeywordTest`,
  `TreeTraversalTest`. Verified: the same tests pass cleanly when
  the file is run in isolation (`mix test path/to/file.exs`,
  3 consecutive iterations, 0 failures, 0.2 s).
- Mechanism: 3 concurrent BEAM VMs (root + mcp_server + dialyzer)
  saturate this 10-core box's scheduler. The `PtcRunner.Sandbox`
  per-program 1 s wallclock is hard (enforced by
  `Process.send_after` → `Process.exit(:kill)`). Programs that
  normally complete in ~50 ms get scheduled-out long enough to blow
  through 1000 ms wallclock and trip the timer. Result: timeout
  `:error` instead of expected return value, MatchError at the
  test site.
- 1 sequential run (out of 10) failed with a *different*,
  pre-existing flake (`PtcRunner.Lisp.RegistryTest`,
  `binary_to_existing_atom("ends-with?")` startup race). Not
  related to parallelization. Recorded for completeness; does not
  count toward criterion #4 since it pre-dates this phase.

**Per the multi-criterion threshold:**

| Criterion | Result |
|---|---|
| Statistically repeatable positive median win | ✅ 13.48 s, n=9 vs n=5 clean |
| No p95 regression | ✅ p95 *improves* by ~37 s |
| ≥5 s median improvement, OR trivial impl + stable smaller win | ✅ 13.48 s ≥ 5 s |
| **No new flakes introduced** | ❌ **5/10 parallel runs hit a brand-new sandbox-timeout flake class** |

3 of 4 hold. Criterion #4 explicitly governs the abort. Per plan:
*"Otherwise abort and document the negative result so a future
revision doesn't re-attempt this phase blindly."*

**Why parallel can't be made safe by the hook alone:** the failing
assertions are in production-test code, not in the hook. Their
implicit precondition is "the BEAM running this test gets enough
CPU to execute a 50 ms PTC-Lisp program inside a 1000 ms wallclock
budget." That precondition holds when one BEAM owns the box; it
breaks when three BEAMs share it on a 10-core machine. Fixes that
*could* be revisited later but were out-of-scope for Phase 2 as
specified:

- Bump `Sandbox`'s default wallclock budget (production-behavior
  change, not a perf-phase change). Almost certainly the wrong
  answer — the budget is asserted on by tests for a reason.
- Re-baseline every Sandbox-budgeted test against a known load
  factor and use a higher budget under contention. Invasive.
- Run dialyzer for all 3 projects sequentially first, then test
  for all 3 projects in parallel (or vice versa). Splits the win
  in half; not measured.
- Move the Sandbox-budgeted tests behind a `:cpu_sensitive` tag
  excluded from the parallel-pre-push path. Drops gate coverage
  on exactly the tests that proved most sensitive to environment
  changes — anti-pattern.

None of these belong in the phase as specified. A future revision
that wants to re-attempt parallel subproject checks should design
around this finding (e.g., gate parallelism on `nproc ≥ 16`, or
restructure the Sandbox tests to use mock time instead of wallclock).

**No refactor commit.** `.githooks/pre-push` and `.githooks/README.md`
are unchanged. The plan revision and this outcome subsection ship as
the single Phase 2 commit on `perf/phase2-parallel-subprojects`.

**Next phase impact:** Phase 3 (mix-via-Port) was already conditional
on re-profiling. The seq-baseline median of 57.93 s shows code-touching
pushes still cost about as much as pre-Phase-1 (53 s baseline; the
slight increase reflects machine load + post-rebase suite growth, not
regression). Phase 3's hypothesis (mix-via-port lock contention is the
remaining bottleneck) survives Phase 2's negative result and remains
worth re-profiling.

## Old Phase 2 (RETIRED) — Flip safe `async: false` files in `mcp_server/test/`

> **Status: RETIRED** (per Revision 4). Hypothesis falsified during
> execution: of 25 default-path sync files, only 1 was safely
> flippable (`cancellation_phase1a_test.exs`). Three other plausible
> candidates exposed real failure modes under load. The other 21
> files mutate `Application.put_env`, global registries,
> `:persistent_term`, or telemetry — sync for real reasons. The
> Phase 2 attempt is preserved in a stash; not shipping. Codex
> consult: "documentation debt masquerading as progress."
>
> Section preserved below for archival reference.



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

- 25-seed loop passes green (multiple `--seed` flags do *not* run
  multiple suites — must be a loop):
  ```bash
  (cd mcp_server && \
    for s in $(seq 0 24); do \
      mix test --seed "$s" || { echo "FAIL seed=$s"; exit 1; } \
    done)
  ```
- Stress variant — vary scheduler concurrency, not just ordering.
  3 seeds × 3 `--max-cases` settings = 9 runs, all green:
  ```bash
  (cd mcp_server && \
    for cases in 1 4 20; do \
      for s in 0 7 13; do \
        mix test --seed "$s" --max-cases "$cases" || \
          { echo "FAIL seed=$s cases=$cases"; exit 1; } \
      done \
    done)
  ```
  Captures races that only surface at specific schedule densities
  (low `--max-cases` exposes single-thread-only invariants; high
  exposes contention).
- `rg 'async:\s*false' mcp_server/test/ -l | grep -v '/integration/' | wc -l`
  (excluding integration files, which Phase 2 doesn't touch)
  decreases measurably from the baseline 25 — target: at least 8
  files flipped.
- For every file *not* flipped, a one-line comment explains why
  sync is required (specific shared-state reference). No file is
  left as `async: false` without a recorded reason.
- mcp_server suite wallclock decreases by ≥3 s on a 20-core box.

**Risk:** New flakes from races previously masked by serialization.
Mitigation: 25-seed sweep is much stronger than 5× same-seed; any
file that flakes flips back with the failure mode recorded.

**Estimated impact:** mcp_server suite from 23 s → ~15–17 s.

## Phase 3 (CONDITIONAL) — Eliminate `mix`-via-`Port.open` from default test paths

> **Status: CONDITIONAL** (per Revision 4). Re-profile after the
> new Phase 2 (parallel subprojects) lands. Original Phase 3
> rationale ("removes the lock-contention cliff") still holds for
> code-touching pushes, but the absolute wallclock left to attack
> may be small enough that the implementation cost (compile-time
> escript build + mix.exs alias) isn't justified. Codex consult:
> "Do it only after measuring how much wallclock is actually
> attributable to those subprocesses under the current hook."
>
> **Retirement criteria:** if post-Phase-2 re-profiling shows
> that `mix run`-via-`Port.open` accounts for **<10% of remaining
> pre-push wallclock** on code-touching pushes, or the lock-
> contention warning ("Waiting for lock on the build directory")
> doesn't appear across 25 consecutive `mix test` runs of
> `mcp_server`, retire Phase 3 with a recorded rationale. If
> ≥10% and the warning fires, ship Phase 3 as specified below.
>
> The original spec is preserved as-is below; the *go/no-go*
> decision is gated on re-profiling.



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
   exec. **Build the artifact at compile time, not at test runtime
   — building inside `setup_all` or any test process re-introduces
   the mix/build-lock contention this phase exists to remove.**

   **Critical: the integration point doesn't exist yet.** Verified
   2026-05-09: `mcp_server/mix.exs` has an `aliases/0` block with
   only `precommit`, `mcp.start`, `mcp.run` — no `compilers:` list,
   no `test` alias. Phase 3 must explicitly *create* whichever
   integration point it picks. This is part of the work, not a
   plug-in.

   Concrete options (pick during execution):

   1. **Add a `test` alias** in `mcp_server/mix.exs`:
      ```elixir
      defp aliases, do: [
        precommit: [...existing...],
        mcp.start: [...],
        mcp.run: [...],
        test: ["compile.mock_escript", "test"]   # NEW
      ]
      ```
      Plus a small `Mix.Tasks.Compile.MockEscript` module in
      `mcp_server/lib/mix/tasks/` that builds the escript only when
      stale. Simplest. Recommended default.
   2. **Add a `:mock_escript` entry to a `compilers:` list** in
      `mcp_server/mix.exs`. Requires more boilerplate (the project
      currently has no `compilers:` key, so Mix uses defaults; we'd
      have to declare them all explicitly to add ours). Heavier;
      only if option 1 turns out insufficient.
   3. **Static path under `mcp_server/test/support/_build/`** —
      rejected because escripts are platform-specific.
B. **Replace `mix run`-port spawn with a Burrito-style standalone
   release** if deps are heavy. Bigger change; probably overkill.
C. **Move tests that genuinely need a real subprocess to
   `:integration` tag**, excluded from the default path. Trade-off:
   default path no longer covers stdio-protocol behaviors against a
   real subprocess. Probably unacceptable; flag if it's the only
   viable path.

Default plan: option A with the compile-time build approach,
unless something prevents it.

**Acceptance:**

- All forms of mix-via-port are gone from default test paths:
  ```bash
  rg --type elixir \
    'command:\s*"mix"|command:\s*System\.find_executable\(.*"mix"\)|exec\s+mix' \
    mcp_server/test mcp_server/lib | grep -v '/integration/'
  ```
  returns zero hits. Broadened from the previous draft to catch
  `System.find_executable("mix")` and `exec mix` in wrapper
  scripts.
- The wrapper shell script at
  `mcp_server/test/ptc_runner_mcp/upstream_stdio_phase1b_test.exs:734`
  is updated to invoke the escript directly, not `mix run`.
- The "Waiting for lock on the build directory" warning does not
  appear across 10 consecutive `(cd mcp_server && mix test)` runs
  with random seeds. (Necessary but not sufficient — the structural
  grep above is the primary acceptance.)
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

## Old Phase 4 (SHELVED) — Pool upstream subprocess fixtures (architectural)

> **Status: SHELVED** (per Revision 4). Old Phase 2's lessons
> demonstrated the suite has real global-state sensitivity (only
> 1/25 sync files was safely flippable; 3 candidates exposed real
> races under load). Pooling fixtures is invasive and likely to
> create hidden state coupling. Codex consult: "Keep it shelved
> unless Phase 3 measurements prove subprocess startup dominates and
> pooling is the only remaining credible fix."
>
> Section preserved below for archival reference.



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
3. **Tests in groups 1–2 (echo, slow) are candidates for pooling**,
   *if* a per-checkout state reset hook is added to the mock server
   (separate small refactor). Group 6 (backoff) is removed from the
   pooling-candidate list — codex pointed out that listing backoff
   state as a per-test-spawn invariant under §"Invariants" #2 and
   then partially exempting it for pooling without defining the
   reset proof is incoherent. Backoff tests keep per-test spawn
   unless a future revision defines a verified reset protocol.
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
- Pool-eligible tests pass under the 25-seed loop *and* the 9-run
  scheduler-density stress (same protocol as Phase 2 — the loops,
  not multiple `--seed` flags in one command).
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
