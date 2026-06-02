# Release Checks — Spec

> Design spec for a bundled **release-checks** GitHub Actions workflow.
> Status: **spec only — not yet implemented**. Implement in a later session.
> Owner: release tooling. Tracking: extends `mcp_server/RELEASING.md`; the root
> project currently has no release checklist (gap identified 2026-06-02).

## 1. Goal

One workflow that runs the heavyweight release-readiness checks that the normal
PR gate (`test.yml`) and `release.yml` do **not** run today:

1. **Memory soak** — no new leaks (atoms / refc-binaries / processes).
2. **Performance** — no new bottlenecks (deterministic reductions/allocations).
3. **Documentation** — no ExDoc warnings, no broken links, no generated-doc drift.
4. **Real-LLM smoke** — the agentic loop actually works against a live model.

## 2. Trigger policy (hard requirement)

Run **only** on a release tag push **or** manual dispatch. **Never** on `push`
to a branch, on `pull_request`, or on a schedule.

```yaml
on:
  push:
    tags: ['v*']        # root library release. Add 'mcp-v*' if mcp_server release should run it too.
  workflow_dispatch:
    inputs:
      llm_runs:   { description: 'demo --runs per suite', type: string, default: '1' }
      skip_llm:   { description: 'skip the real-LLM smoke', type: boolean, default: false }
```

## 3. Gating policy (hard requirement)

| Check | Fails the workflow? | Notes |
|-------|--------------------|-------|
| Memory soak | **yes** (gate) | a leak must block a release |
| Performance | **yes** (gate) | only on *deterministic* metrics (reductions/allocations), never wall-clock |
| Documentation | **yes** (gate) | ExDoc warnings + broken **relative** links + gen-doc drift |
| Real-LLM smoke | **NO — never fails** | stats only; emits a summary, always exits 0 |
| External-URL links (docs) | **no** (informational) | external URLs flake; report but don't gate |

The real-LLM job must be **non-blocking by construction**: every LLM command is
wrapped so a model error, a wrong answer, a 429, or an OpenRouter outage produces
**stats**, not a red build. The publish job (`release.yml`) must **not** list the
LLM job in `needs:`.

## 4. Architecture

Implement as a **reusable workflow** so it both gates the real publish and runs on
demand:

- `release-checks.yml` — `on: [workflow_call, workflow_dispatch, push(tags)]`, holds
  all four jobs. The three gating jobs run to completion and fail the run on a real
  regression; the LLM job always succeeds.
- `release.yml` (existing Hex publish) — add `uses: ./.github/workflows/release-checks.yml`
  as a prerequisite and make the `publish` job `needs: [soak, perf, docs]` (the gating
  jobs), **not** the LLM job. This makes soak/perf/docs actually block the Hex publish
  while keeping the LLM smoke informational.

All jobs reuse the existing `./.github/actions/setup-elixir` composite (Elixir 1.19.3 /
OTP 28.1, deps + `_build` + PLT cache). `bb` is **not** needed (no `:clojure` tests here).

```
release tag  ──► release-checks.yml ──► [soak]  [perf]  [docs]  [llm-smoke]
                                          gate    gate    gate    stats-only
release.yml publish  needs: [soak, perf, docs]   ───────────────► hex.publish
                     (does NOT need llm-smoke)
```

## 5. Per-check specs

### 5A. Memory soak — `soak` job (gate)

- Command: `mix test --only soak` with `MIX_ENV=test`, `PTC_SOAK_ITERATIONS=3000`
  (3–5k is the CI sweet spot: real signal, but below the 1 s/eval sandbox timeout's
  contention cliff — see `private/Plans/pre-push-perf.md`).
- Covers (already implemented, see `test/soak/` + `test/support/memory_soak.ex`):
  `atom_leak_soak`, `closure_capture_soak`, `tracer_soak` — hard `assert_*` thresholds.
- `:recon` is already a `:test` dep (`mix.exs:78`), so `bin_leak` diagnostics work in CI.
- **mcp_server soak** (`mcp_server/test/soak/`): include `session_churn`, `many_turns`,
  `http_mcp` (`cd mcp_server && PTC_SOAK_ITERATIONS=3000 mix test --only soak`).
  **Exclude `mcp_stdio_soak`** from the gate (needs `MIX_ENV=prod mix release` first and
  has a known `:epipe` flake on this stack — run it `continue-on-error` in a separate
  step if wanted).
- `timeout-minutes: 20`. Gate: job fails ⇒ workflow fails.

### 5B. Performance — `perf` job (gate; **Phase 2**, most involved)

Hosted runners are too noisy for wall-clock gating (±20–50%). Gate on **deterministic**
metrics only:

- Enable `reduction_time` in `bench/lisp_throughput.exs` Benchee config (currently
  `memory_time: 1`, no reductions) so we measure **reductions + memory bytes** per
  scenario — both CPU-noise-independent.
- New mix task **`mix bench.check`**: runs the bench, loads a committed baseline
  (`bench/baselines/lisp_throughput.json`, Benchee `save:`/`load:`), and **fails** if
  reductions or memory for `full Lisp.run/2` (and key archetypes) regress beyond a
  threshold (e.g. **+7%**). Wall-clock is recorded but **informational**.
- Baseline lifecycle: regenerate the baseline JSON when an intentional perf change
  lands (document the command in the task's `@moduledoc`); commit it.
- `timeout-minutes: 15`. Gate: reductions/allocations regression ⇒ fail.
- **Out of scope:** stable absolute wall-clock (would need a self-hosted/pinned runner);
  optional `github-action-benchmark` gh-pages trend dashboard for wall-clock history.

### 5C. Documentation — `docs` job (gate)

Three sub-checks; the first two gate, external URLs are informational:

1. **ExDoc warnings** — `MIX_ENV=dev mix docs` and fail on warnings (broken `m:Module` /
   `` `Mod.fun/arity` `` refs, broken `extras` links). Use `mix docs --warnings-as-errors`
   if the pinned ExDoc `~> 0.31` supports it; otherwise capture output and fail if it
   contains `warning:`. *(verify the flag at impl)*
2. **Generated-doc drift** — `mix ptc.gen_docs && mix ptc.conformance_report --write-inventory`
   then `git diff --exit-code -- docs/ conformance_inventory.json`. Fails if generated
   docs (function-reference.md, `docs/conformance/*.md`, inventory) are stale vs source
   (`priv/functions.exs`, audit files). *(This is exactly the drift the 2026-06-02
   conformance batch had to fix by hand.)*
3. **Broken links** — add **lychee** (`lycheeverse/lychee-action`) over `**/*.md`
   (README, `docs/`, `mcp_server/*.md`):
   - **`--offline` relative-link pass = GATE** (deterministic: dead `docs/...` / `[[name]]`
     / section-anchor links).
   - online external-URL pass = **separate, informational** step (`fail: false`), with a
     `.lycheeignore` for known-volatile hosts.
- `timeout-minutes: 10`.

### 5D. Real-LLM smoke — `llm-smoke` job (**never fails**, stats only)

- **Model:** `gemini-flash-lite` alias ⇒ `openrouter:google/gemini-3.1-flash-lite`
  (already in `lib/ptc_runner/llm/default_registry.ex:86`). No registry change needed.
- **Env:** `OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}` (the same secret
  `benchmark.yml` already uses), `LLM_DEFAULT_PROVIDER: openrouter`,
  `PTC_TEST_MODEL: gemini-flash-lite`.
- **Job-level `continue-on-error: true`** AND every command wrapped (`|| true`) so the
  job is always green. Publish does **not** `need` this job.
- **Runs both surfaces the user asked for:**
  1. **Demo benchmarks** (reuse the maintained `benchmark.yml` path):
     ```
     cd demo
     mix lisp --test --runs=${{ inputs.llm_runs || 1 }} --model=openrouter:google/gemini-3.1-flash-lite --report=tmp/lisp.md || true
     mix json --test --runs=${{ inputs.llm_runs || 1 }} --model=openrouter:google/gemini-3.1-flash-lite --report=tmp/json.md || true
     ```
     Parse `summary.passed/total`, pass-rate %, `stats.total_tokens`
     (see `demo/lib/ptc_demo/lisp_test_runner.ex`).
  2. **e2e tests** (root, real model):
     ```
     PTC_TEST_MODEL=gemini-flash-lite mix test --include e2e --formatter ... || true
     ```
     e2e tests are assertions, so with a cheap model some may fail — that's expected and
     **not** a build failure. Capture `N tests, M failures` + per-file results.
- **Output:** write a stats block to `$GITHUB_STEP_SUMMARY`: demo pass-rates + token
  cost, e2e passed/total + which failed, total wall time, model id. Upload the demo
  report markdown as an artifact.
- `timeout-minutes: 25` (the full `:e2e` suite is multi-turn agentic across many files;
  bound it). Cost: gemini-3.1-flash-lite is cheap; one pass ≈ cents. Release/manual
  cadence keeps spend negligible.
- **Implementer note:** confirm how to surface ExUnit pass/fail counts even on failure
  (JUnit/`--formatter`, or parse the summary line). Optionally scope the heaviest e2e
  files behind a separate non-gating step if 25 min is tight.

## 6. Failure semantics (summary)

- Workflow is **red** iff: a soak assertion fails, a perf reduction/alloc regression
  exceeds threshold, ExDoc warns, a relative doc link is broken, or generated docs drift.
- Workflow stays **green** for: any LLM behavior (wrong answers, model/API errors,
  outages), and dead external URLs.

## 7. New / changed files (implementation checklist)

- `.github/workflows/release-checks.yml` (new) — the 4-job reusable workflow.
- `.github/workflows/release.yml` (edit) — `publish` `needs: [soak, perf, docs]` via
  `workflow_call`.
- `bench/lisp_throughput.exs` (edit) — add `reduction_time: 1`.
- `lib/mix/tasks/bench.check.ex` (new) — baseline compare + threshold (Phase 2).
- `bench/baselines/lisp_throughput.json` (new) — committed deterministic baseline (Phase 2).
- `.lycheeignore` (new) — known-volatile external hosts.
- `docs/RELEASING.md` (new, optional) — root-project release checklist mirroring
  `mcp_server/RELEASING.md`, referencing this workflow.
- No model/registry change (alias already exists). No new dep for soak/perf
  (`:recon`, `:benchee` already in `:test`/`:dev`). Docs job needs the lychee action only.

## 8. Open questions / verify at implementation

1. ExDoc `~> 0.31`: confirm `mix docs --warnings-as-errors` exists; else grep output.
2. Perf threshold %: start at +7% on reductions for `full Lisp.run/2`; tune after one
   real baseline.
3. Should the LLM smoke also drive the **released mcp_server binary** (highest-fidelity)?
   `mcp_server/bench/agentic_real_eval.exs` + `lisp_eval_real_client_eval.exs` already do
   real-LLM turns through the server — could be a Phase 3 step inside the mcp `RELEASING.md`
   artifact smoke (currently protocol-only: `(+ 1 2)` ⇒ `user=> 3`).
4. Confirm whether `mcp-v*` tags should also trigger this workflow (mcp release) or only `v*`.
5. e2e suite duration on gemini-flash-lite — measure once; adjust `timeout-minutes`.

## 9. Phasing (suggested)

- **Phase 1 (small, high value):** `soak` gate + `docs` gate (ExDoc + lychee offline +
  gen-doc drift) + `llm-smoke` (demo + e2e, stats-only). Wire `release.yml needs`.
- **Phase 2:** `perf` gate (`reduction_time` + `mix bench.check` + baseline).
- **Phase 3 (optional):** mcp_server real-agentic smoke; wall-clock trend dashboard;
  promote `private/mcpproxy/` HTTP benches into the tracked toolchain.

## 10. Acceptance criteria

- Pushing a `v*` tag runs all four jobs; a seeded leak / perf regression / broken
  relative link / ExDoc warning / gen-doc drift turns the run red and blocks publish.
- A wrong LLM answer or a simulated OpenRouter 429 leaves the run green, with a stats
  summary visible in the job summary.
- The workflow never runs on a PR or on a schedule.
- Manual `workflow_dispatch` runs the same checks on demand (with `skip_llm` honored).
