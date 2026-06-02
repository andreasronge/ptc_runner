# Release Checks — Spec

> Design spec for bundled release-readiness checks in GitHub Actions.
> Status: **Phase 1 implemented**. Keep this document as design rationale and
> future-work notes; use `docs/RELEASING.md` for the operational checklist.
> Revised 2026-06-02 after review (workflow topology + perf-metric corrections).
> Extends `docs/RELEASING.md` and `mcp_server/RELEASING.md`.

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
    tags: ['v*']        # root library release. (Decision: also 'mcp-v*'? — see §8)
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
  release-report:
    if: always()
    needs: [test, soak, integrity, docs, perf, llm-smoke]
    continue-on-error: true                # §5E — reporting only
  publish:
    needs: [test, soak, integrity, docs, perf] # gates; NOT llm-smoke
    if: ${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}
    steps: [hex.build, hex.publish, hex.publish docs]
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
- All jobs reuse `./.github/actions/setup-elixir` (Elixir 1.19.3 / OTP 28.1; caches
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
   then `git diff --exit-code -- docs/ conformance_inventory.json`. (Exactly the drift the
   2026-06-02 conformance batch had to fix by hand.)
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

## 6. Failure semantics (summary)

- **Red** iff: `mix test` fails, a soak assertion fails, `mix bench.check` detects
  an eval-reduction regression, version/changelog mismatch,
  package omits expected `priv/*`, schema/spec drift, an ExDoc warning, a broken
  **relative** doc link, or gen-doc drift.
- **Green** for: any LLM behavior (wrong answers, model/API errors, outages) and dead
  **external** URLs.
- A release report is emitted for both green and red runs. Report generation itself is
  non-gating.

## 7. New / changed files (implementation checklist)

- `.github/workflows/release.yml` (**restructure**) — multi-job: `test`, `soak`,
  `integrity`, `docs`, `llm-smoke`, `release-report`, `publish` (`needs` gates only;
  publish guarded by `github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')`).
- `.github/actions/setup-elixir/action.yml` (optional) — add `skip-babashka` input;
  optionally cache/fetch `mcp_server/deps` (or do `mix deps.get` in the soak job).
- `.lycheeignore` (new) — volatile external hosts.
- `CHANGELOG.md` — ensure a `## [<version>]` section exists per release (now gated).
- **Phase 2:** `lib/ptc_runner/sandbox.ex` (capture child reductions),
  `lib/mix/tasks/bench.check.ex`, `bench/baselines/*.json`.
- `docs/RELEASING.md` — root release checklist mirroring `mcp_server/RELEASING.md`.
- No model/registry change. No new runtime deps (`:recon`/`:benchee` already present);
  docs job adds the lychee action only.

## 8. Open decisions for the implementer

1. **`mcp-v*` tags** — should this workflow also run on the mcp_server release tag, or
   only `v*`?
2. **Perf threshold %** — start +7% on child eval reductions; tune after several releases.
3. **mcp_server real-agentic smoke** — Phase 3: drive the *released* mcp binary with a
   real LLM via `mcp_server/bench/agentic_real_eval.exs` inside the `RELEASING.md` artifact
   smoke (currently protocol-only: `(+ 1 2)` ⇒ `user=> 3`).
4. e2e duration on gemini-3.1-flash-lite — measure once; tune `timeout-minutes`.

## 9. Phasing (suggested)

- **Phase 1 (small, high value, low ambiguity):** restructure `release.yml` with
  `test` + `soak` + `integrity` (version/changelog/package/schema/spec) + `docs`
  (ExDoc/lychee-offline/gen-doc drift) gating the publish, plus non-blocking
  `llm-smoke` (demo + e2e on gemini-3.1-flash-lite, stats-only), plus a non-gating
  `release-report` artifact/step summary.
- **Phase 2:** the perf gate — sandbox child-reduction instrumentation + `mix bench.check`
  + committed baseline. (Implemented; do **not** replace with a Benchee-full-run gate.)
- **Phase 3 (optional):** mcp_server real-agentic smoke through the released binary;
  wall-clock trend dashboard; promote `private/mcpproxy/` HTTP benches into the toolchain.

## 10. Acceptance criteria

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

## 11. Post-merge smoke test

Run this after the workflow change has been merged to `main`. GitHub only exposes
`workflow_dispatch` for workflow files present on the default branch, so a branch-only
workflow edit is not enough to smoke it from the Actions UI.

1. Manually trigger `release.yml` from the Actions tab on `main` with `skip_llm: true`.
   This is the cheap deterministic smoke. Confirm `test`, `soak`, `integrity`, and
   `docs` run; `publish` is skipped; and `release-report` uploads the
   `release-checks-report` artifact.
2. Manually trigger it again with `skip_llm: false` and `llm_runs: 1`. Confirm the
   LLM job produces stats/artifacts, stays non-gating, and the release report records
   the LLM results as informational.
3. Optional safety check: manually dispatch on a `v*` tag ref and confirm `publish`
   still skips because publish requires `github.event_name == 'push'`.
