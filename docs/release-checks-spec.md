# Release Checks — Design Record

> Design record for bundled release-readiness checks in GitHub Actions.
> This is **not** the release checklist. Use `docs/RELEASING.md` for the root
> release procedure and `.github/workflows/release.yml` for implemented CI
> behavior. If this document disagrees with either one, the checklist and
> workflow win.
> Revised 2026-06-03 to remove stale planning notes and align current behavior.

## 1. Goal

Run the heavyweight release-readiness checks that the PR gate (`test.yml`) does not:

1. **Memory soak** — no new leaks (atoms / refc-binaries / processes).
2. **Release integrity** — version/changelog match, Hex package actually bundles
   `priv/*`, no schema/spec drift.
3. **Documentation** — no ExDoc warnings, no broken links, no generated-doc drift.
4. **Real-LLM smoke** — the agentic loop works against a live model (stats only).
5. **Release report** — one markdown result showing what ran, what passed/failed,
   and where artifacts/logs are.
6. **Performance** — child eval reductions versus a committed baseline.

## 2. Trigger policy (hard requirement)

Run **only** on a release tag push **or** manual dispatch. **Never** on a branch
`push`, on `pull_request`, or on a schedule.

```yaml
on:
  push:
    tags: ['v*']        # root library release only. mcp_server uses mcp-v* elsewhere.
  workflow_dispatch:
    inputs:
      llm_runs: { description: 'demo --runs per suite', type: string, default: '1' }
      skip_llm: { description: 'skip the real-LLM smoke', type: boolean, default: false }
```

## 3. Architecture — ONE workflow (corrected)

> Review correction: do **not** use a reusable workflow. A caller can only
> `needs:` the single job that `uses:` a reusable workflow (not its inner jobs),
> and a shared tag trigger double-runs the checks. Put everything in one
> `release.yml` (restructured from the current single-job version).

All check jobs live in `release.yml`. The `publish` job `needs:` the **gating**
jobs only and is guarded by both event type and tag ref so manual dispatch runs
checks **without** publishing:

```yaml
jobs:
  test:       { ... }                      # existing `mix test` (default tags)
  soak:       { ... }                      # §5A
  integrity:  { ... }                      # §5B
  docs:       { ... }                      # §5C
  perf:       { ... }                      # §5F
  llm-smoke:  { continue-on-error: true,   # §5D — never blocks
                if: ${{ github.event_name != 'workflow_dispatch' || !inputs.skip_llm }} }
  stats:      { continue-on-error: true }   # §5G — code/test stats, never blocks
  coverage:   { continue-on-error: true }   # §5H — mix test --cover, never blocks
  release-report:
    if: always()
    needs: [test, soak, integrity, docs, perf, llm-smoke, stats, coverage]
    continue-on-error: true                # §5E — reporting only
  publish:
    needs: [test, soak, integrity, docs, perf] # gates; NOT llm-smoke
    if: ${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}
    steps: [hex.build, hex.publish, hex.publish docs]
  github-release:                              # §5I — tag push ONLY, gates green
    needs: [test, soak, integrity, docs, perf, release-report, stats, coverage]
    if: always() && push && refs/tags/v && all five gates == success
    steps: [download report+metrics, assemble release-metrics.json,
            compose notes (changelog + report), gh release create]
```

This gates the Hex publish on soak/integrity/docs/test, keeps the LLM smoke as
pure signal, runs checks-without-publish on manual dispatch (even if the manual
run targets a `v*` tag), emits a report regardless of pass/fail, and avoids any
double-trigger.

`inputs.*` is only defined for `workflow_dispatch`/reusable workflows, so use
event guards before reading boolean inputs at job level. For shell defaults used
by jobs that also run on tag push, prefer a resolved env var such as:

```yaml
env:
  LLM_RUNS: ${{ github.event.inputs.llm_runs || '1' }}
```

### Shared setup gotchas (verified)
- All jobs reuse `./.github/actions/setup-elixir` (Elixir 1.20.0 / OTP 28.5.0.1; caches
  `deps`, `_build`, `demo/deps`, PLT). **It does NOT touch `mcp_server`**
  (`action.yml:21,33` cache/fetch root + demo only) — any MCP job must add
  `working-directory: mcp_server` + `mix deps.get` (and ideally cache `mcp_server/deps`).
- The action **always installs Babashka** (`action.yml:50`, `mix ptc.install_babashka`
  unless cached). These checks don't need `bb`; it's harmless on a cache-hit. Optional
  polish: add a `skip-babashka` input to the action.

## 4. Gating policy (hard requirement)

| Check | Fails the workflow? | Phase |
|-------|--------------------|-------|
| `test` (`mix test`, default tags) | **yes** | 1 |
| Memory soak | **yes** | 1 |
| Release integrity (version/changelog/package/schema/spec) | **yes** | 1 |
| Documentation (ExDoc warnings, relative links, gen-doc drift) | **yes** | 1 |
| Real-LLM smoke | **NO — never fails** (stats only) | 1 |
| Code & test stats | **NO — never fails** (informational) | 1 |
| Test coverage (`mix test --cover`) | **NO — never fails** (informational) | 1 |
| Release report | **NO — never fails** (summary only) | 1 |
| External-URL links (docs) | **no** (informational) | 1 |
| Performance (deterministic eval reductions) | **yes** | 2 |

The real-LLM job is non-blocking **by construction**: every LLM command is wrapped
(`|| true`) and the job is `continue-on-error: true`; `publish` does not `needs:` it.

## 5. Per-check specs

### 5A. Memory soak — `soak` job (gate, Phase 1)

- Root: `MIX_ENV=test PTC_SOAK_ITERATIONS=3000 mix test --only soak` (3–5k is the CI
  sweet spot — real signal, below the 1 s/eval sandbox-timeout contention cliff per
  `private/Plans/pre-push-perf.md`). Covers `atom_leak`, `closure_capture`, `tracer`
  (`test/soak/`). `:recon` is already a `:test` dep (`mix.exs:78`).
- mcp_server: needs its own `cd mcp_server && mix deps.get` first. Use
  `--only soak` with the explicit file list; ExUnit excludes `:soak` by default, and
  the file list keeps `mcp_stdio_soak_test.exs` out of the gate:
  ```
  cd mcp_server && mix deps.get
  PTC_SOAK_ITERATIONS=3000 mix test --only soak \
    test/soak/session_churn_soak_test.exs \
    test/soak/many_turns_soak_test.exs \
    test/soak/http_mcp_soak_test.exs
  ```
  `mcp_stdio_soak` (needs `MIX_ENV=prod mix release` + has a known `:epipe` flake) is
  out of the gate; run it `continue-on-error` in a separate step if wanted.
- `timeout-minutes: 20`.

### 5B. Release integrity — `integrity` job (gate, Phase 1)

- **Version/tag match** — already in `release.yml:20` (tag `v$X` == `mix.exs` version); keep it.
- **Changelog gate** — require `CHANGELOG.md` to contain a `## [<version>]` heading for
  the tag version (fail if missing).
- **Package contents** (the high-value footgun check) — `mix hex.build --unpack`, then
  **assert the bundled `files:` include**
  `priv/prompts/`, `priv/spec/`, `priv/ptc_schema.json`, the generated references,
  and docs. Catches a `priv/*` omission before it ships to Hex.
- **Schema drift** — `mix schema.gen && git diff --exit-code -- priv/ptc_schema.json`.
- **Spec checksums** — `mix ptc.validate_spec` (already treated as important by
  `mix precommit`).
- `timeout-minutes: 10`.

### 5C. Documentation — `docs` job (gate, Phase 1)

1. **ExDoc warnings** — `MIX_ENV=dev mix docs --warnings-as-errors` (flag **confirmed**
   present in the pinned ExDoc `~> 0.31`). Catches broken `m:Module` / `` `Mod.fun/arity` ``
   / `extras` refs.
2. **Generated-doc drift** — `mix ptc.gen_docs && mix ptc.conformance_report --write-inventory`
   then `git diff --exit-code -- docs/ conformance_inventory.json` plus
   `git status --porcelain -- docs/ conformance_inventory.json` so newly generated,
   untracked files fail too. (Exactly the drift the 2026-06-02 conformance batch had
   to fix by hand.)
3. **Broken links (lychee, scoped globs — not `**/*.md`)** — run
   `lycheeverse/lychee-action` over explicit paths only (`README.md`, `docs/**/*.md`,
   `mcp_server/*.md`) to avoid `deps/`, `tmp/`, and generated trees:
   - **`--offline` relative-link pass = GATE** (deterministic dead `docs/...` / `[[name]]`
     / anchor links).
   - online external-URL pass = **separate, informational** step (`fail: false`) +
     `.lycheeignore` for volatile hosts.
- `timeout-minutes: 10`.

### 5D. Real-LLM smoke — `llm-smoke` job (**never fails**, stats only, Phase 1)

- **Model:** `gemini-flash-lite` alias ⇒ `openrouter:google/gemini-3.1-flash-lite`
  (`lib/ptc_runner/llm/default_registry.ex:86`; matches the current OpenRouter listing
  `google/gemini-3.1-flash-lite`). No registry change.
- **Env:** `OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}` (same secret
  `benchmark.yml` uses), `LLM_DEFAULT_PROVIDER: openrouter`,
  `PTC_TEST_MODEL: gemini-flash-lite`, `LLM_RUNS: ${{ github.event.inputs.llm_runs || '1' }}`.
- **`continue-on-error: true`** + every command wrapped `|| true`; `publish` does not
  `needs:` it.
- **Both surfaces:**
  1. Demo benchmarks (reuse the maintained `benchmark.yml` path):
     ```
     cd demo
     mix lisp --test --runs="${LLM_RUNS}" --model=openrouter:google/gemini-3.1-flash-lite --report=tmp/lisp.md || true
     ```
     Parse `summary.passed/total`, pass-rate %, `stats.total_tokens`
     (`demo/lib/ptc_demo/lisp_test_runner.ex`). Relative report paths are resolved
     under `demo/reports/`, so the example above writes
     `demo/reports/tmp/lisp.md`, `demo/reports/tmp/lisp.json`,
     `demo/reports/tmp/json.md`, and `demo/reports/tmp/json.json`; upload
     `demo/reports/tmp/` as the artifact path.
  2. e2e (root, real model):
     ```
     PTC_TEST_MODEL=gemini-flash-lite mix test --include e2e || true
     ```
     e2e tests are assertions — a cheap model will miss some; that is **stats, not a
     failure**. Capture `N tests, M failures` + per-file results (use a JUnit/`--formatter`
     so counts survive a non-zero exit).
- **Output:** stats block to `$GITHUB_STEP_SUMMARY` (demo pass-rates + token cost, e2e
  passed/total + which failed, wall time, model id); upload demo reports as artifacts.
- `timeout-minutes: 25` (full `:e2e` is multi-turn across many files). Cost: pennies at
  release/manual cadence.

### 5E. Release report — `release-report` job (summary only, Phase 1)

Every run should leave a concise release-readiness record, not just raw job logs.
Each check job writes a small markdown fragment under `tmp/release-report/` and
uploads it as an artifact with `if: always()`. The final `release-report` job
uses `if: always()`, downloads those fragments, and writes:

- `$GITHUB_STEP_SUMMARY` — human-readable table visible from the workflow run.
- `tmp/release-checks.md` — uploaded as a `release-checks-report` artifact.

The report should include:

- repo, commit SHA, ref/tag, workflow run URL, actor, UTC timestamp, Elixir/OTP versions.
- release version and changelog heading result.
- package integrity result, including the unpacked package path and checked bundled files.
- test command list and outcome for `mix test`, root soak, MCP soak, docs, schema/spec drift,
  ExDoc, lychee offline, and external-link informational pass.
- LLM smoke model, run count, demo pass rates, token/cost stats, e2e pass/fail counts, and
  note that these results are non-gating.
- artifact links/names for demo reports, lychee output if available, package unpack output,
  and the release report itself.
- final gate verdict: `READY TO PUBLISH` only when `test`, `soak`, `integrity`, `docs`,
  and `perf` all succeeded; otherwise `BLOCKED`, with the failed job names.

This job must never gate publishing. `publish` continues to depend directly on
`test`, `soak`, `integrity`, `docs`, and `perf`; the report job is for auditability and
operator handoff only. If a gating job fails, `release-report` still runs and
records the failure.

### 5F. Performance — `perf` job (gate, Phase 2)

> Review correction: the original "gate on Benchee reductions for `full Lisp.run/2`"
> is **invalid**. `Lisp.run/2` runs the evaluator in a **spawned child process**
> (`sandbox.ex:141`: `Process.spawn(fn -> eval_fn.(ast, context) ... end)`), and
> Benchee only counts reductions/memory of the *benchmark* process — so it would
> capture parse+analyze + spawn/marshalling and **miss the entire eval**. A Benchee
> baseline over the full run gives false confidence.

Implemented path: the sandbox self-measures child eval reductions alongside child
memory. `mix bench.check` gates representative programs on eval reductions
against `bench/baselines/lisp_eval.json` with a default **+7%** threshold. Child
memory is reported but not gated here; memory regressions are covered by soak
tests because per-process heap size is too noisy for a narrow performance
threshold.

Also: enabling `reduction_time` in `bench/lisp_throughput.exs` only helps the in-process
scenarios; wall-clock stays informational (hosted-runner noise ±20–50%). Wall-clock
trend dashboard (`github-action-benchmark` / gh-pages) is optional, out of scope for a gate.

### 5G. Code & test stats — `stats` job (informational, never fails)

Non-gating snapshot of repository size, growth, and a small health radar,
appended to the release report. Implemented by `scripts/release-stats.sh`
(locally runnable: `scripts/release-stats.sh [out.md]`).

- **Checkout:** `fetch-depth: 0` — full history + tags are required for the
  growth section (diffs against the previous release tag).
- **No Elixir setup:** pure `git`/`awk`; the job is seconds-cheap.
- **Baseline selection:** if a `v*` tag points at HEAD (a real release), the
  baseline is the tag *before* it; otherwise (manual dispatch on `main`) it is
  the latest `v*` tag. Degrades to "growth skipped" when no tag exists.
- **Reported:** lib/test/mcp_server LOC, file & module counts, test-case count,
  **test:code ratio**; growth deltas since the previous tag (lib/test LOC, test
  cases, modules, commits, overall `--shortstat`); health (`@spec` coverage,
  TODO/FIXME count, largest lib file, dependency count).
- **Output:** `## stats` fragment to `tmp/release-report/stats.md` (auto-merged
  by `release-report` via the `release-fragment-*` pattern) and to
  `$GITHUB_STEP_SUMMARY`. Portability: uses `[[:space:]]` (not `\s`) so counts
  match under `git grep -E` and BSD/GNU `awk`.

### 5H. Test coverage — `coverage` job (informational, never fails)

Non-gating line-coverage snapshot using the **built-in** tool (no new
dependency; `mix.exs` already configures `test_coverage` with `ignore_modules`
for Mix tasks and test support). A separate job rather than piggybacking on the
`test` gate so `:cover` instrumentation overhead never threatens the gate's
timeout; the trade-off is one extra suite run.

- **Command:** `mix test --cover` for the root app and `mix test --cover` in
  `mcp_server/`, captured with `set +e` so coverage summaries are parsed even
  when some tests fail.
- **Parser:** `scripts/coverage-stats.sh` reads the summary table (`| <pct>% |
  Module |` rows + the `Total` line) and emits a `## coverage` fragment.
- **Reported:** total line coverage %, modules measured, modules < 50%, modules
  at 0% (the gap signal — a single % hides large untested clusters), with root
  and MCP server shown as separate projects.
- **Output:** `tmp/release-report/coverage.md` (auto-merged by `release-report`)
  and `$GITHUB_STEP_SUMMARY`. Trend-vs-previous-release is a deliberate
  follow-up (it needs a committed baseline %).
- **Soft gate (future):** flip to failing the (still non-publish-blocking) job
  below a threshold by parsing the total — `summary: [threshold: N]` alone does
  not change the exit code.

### 5I. GitHub Release — `github-release` job (tag push only)

Publishes a permanent, per-version GitHub Release so releases are comparable
over time. Actions artifacts (step summaries, `release-*` artifacts) are
ephemeral and not addressable per tag; a Release page and its attached asset are
durable and enable GitHub's `compare/vA...vB` view.

- **Trigger guard (important):** runs **only** on a real tag push
  (`github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')`) and
  **never on `workflow_dispatch`** — manual check runs must not publish a
  Release. The `if` also requires all five gates (`test`, `soak`, `integrity`,
  `docs`, `perf`) to be `success`; `always()` is used only so the non-gating
  `release-report`/`stats`/`coverage` jobs may fail without skipping it.
- **Comparable asset:** `scripts/release-stats.sh` and `scripts/coverage-stats.sh`
  now also emit JSON siblings (uploaded as `release-metrics-*`). The job merges
  them with `jq` into a single **`release-metrics.json`** (version, tag, commit,
  generated-at, `stats`, `coverage`) attached to the Release. Comparing two
  releases = diffing their `release-metrics.json`.
- **Notes:** the `CHANGELOG.md` section for the version (heading → next `## [`)
  followed by the full release-checks report.
- **Idempotent:** re-runs `gh release edit` + `gh release upload --clobber` when
  the Release already exists.
- **Permissions:** `contents: write` at job level (top-level default stays
  `contents: read`).
- **Follow-up:** an in-repo `docs/metrics.md` ledger and/or a Codecov badge are
  natural next steps for at-a-glance trends; out of scope here.

## 6. Failure semantics (summary)

- **Red** iff: `mix test` fails, a soak assertion fails, `mix bench.check` detects
  an eval-reduction regression, version/changelog mismatch,
  package omits expected `priv/*`, schema/spec drift, an ExDoc warning, a broken
  **relative** doc link, or gen-doc drift.
- **Green** for: any LLM behavior (wrong answers, model/API errors, outages) and dead
  **external** URLs.
- A release report is emitted for both green and red runs. Report generation itself is
  non-gating.

## 7. Historical Decisions And Non-Goals

- Root releases use only `v*` tags. The sibling MCP server has its own release
  path and `mcp-v*` tag namespace; do not route those tags through the root
  publish workflow.
- The perf gate uses sandbox child-reduction measurements via `mix bench.check`.
  Do not replace it with Benchee measurements around full `Lisp.run/2`; those
  miss child-process eval reductions.
- Real-LLM smoke stays informational. Wrong model answers, model outages, and
  provider rate limits must be visible in the report but must not block Hex
  publishing.
- Coverage and stats stay informational. They are useful release context, not
  publish gates.
- A future MCP-server real-agentic smoke may drive the released MCP binary with
  a live model, but it should follow the MCP server release process rather than
  changing the root tag namespace.

## 8. Acceptance Criteria

- Pushing a `v*` tag runs the gating jobs; a seeded leak / version-or-changelog mismatch /
  missing `priv/*` in the package / schema or spec drift / broken relative link / ExDoc
  warning / gen-doc drift turns the run red and **blocks publish**.
- A wrong LLM answer or a simulated OpenRouter 429 leaves the run **green**, with a stats
  summary in the job summary.
- The workflow never runs on a PR or on a schedule; `workflow_dispatch` runs the checks
  **without** publishing (publish skipped off-tag), honoring `skip_llm`.
- Every run emits a `release-checks-report` artifact and `$GITHUB_STEP_SUMMARY`
  documenting commands, outcomes, gating verdict, LLM stats, and relevant artifact names.
- (Phase 2) A seeded eval slowdown that inflates child reductions beyond threshold fails
  the `perf` job.
