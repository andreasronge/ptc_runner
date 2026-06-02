# Release Checks — Spec

> Design spec for bundled release-readiness checks in GitHub Actions.
> Status: **spec only — not yet implemented**. Implement in a later session.
> Revised 2026-06-02 after review (workflow topology + perf-metric corrections).
> Extends `mcp_server/RELEASING.md`; the root project currently has no release checklist.

## 1. Goal

Run the heavyweight release-readiness checks that the PR gate (`test.yml`) does not:

1. **Memory soak** — no new leaks (atoms / refc-binaries / processes).
2. **Release integrity** — version/changelog match, Hex package actually bundles
   `priv/*`, no schema/spec drift.
3. **Documentation** — no ExDoc warnings, no broken links, no generated-doc drift.
4. **Real-LLM smoke** — the agentic loop works against a live model (stats only).
5. **Performance** — *deferred (Phase 2)*, see §5E for why and the redesign.

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
jobs only and is guarded by the tag ref so manual dispatch runs checks **without**
publishing:

```yaml
jobs:
  test:       { ... }                      # existing `mix test` (default tags)
  soak:       { ... }                      # §5A
  integrity:  { ... }                      # §5B
  docs:       { ... }                      # §5C
  llm-smoke:  { continue-on-error: true,   # §5D — never blocks
                if: ${{ !inputs.skip_llm }} }
  # perf:     deferred — §5E (add to `needs` once it gates a real metric)
  publish:
    needs: [test, soak, integrity, docs]   # gates; NOT llm-smoke
    if: startsWith(github.ref, 'refs/tags/v')   # skip on workflow_dispatch
    steps: [hex.build, hex.publish, hex.publish docs]
```

This gates the Hex publish on soak/integrity/docs/test, keeps the LLM smoke as
pure signal, runs checks-without-publish on manual dispatch, and avoids any
double-trigger.

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
| External-URL links (docs) | **no** (informational) | 1 |
| Performance (deterministic eval reductions) | **yes** | **2** (redesign first) |

The real-LLM job is non-blocking **by construction**: every LLM command is wrapped
(`|| true`) and the job is `continue-on-error: true`; `publish` does not `needs:` it.

## 5. Per-check specs

### 5A. Memory soak — `soak` job (gate, Phase 1)

- Root: `MIX_ENV=test PTC_SOAK_ITERATIONS=3000 mix test --only soak` (3–5k is the CI
  sweet spot — real signal, below the 1 s/eval sandbox-timeout contention cliff per
  `private/Plans/pre-push-perf.md`). Covers `atom_leak`, `closure_capture`, `tracer`
  (`test/soak/`). `:recon` is already a `:test` dep (`mix.exs:78`).
- mcp_server: needs its own `cd mcp_server && mix deps.get` first. **Do NOT use
  `--only soak`** — that also selects `mcp_stdio_soak_test.exs` (only skipped when the
  release binary is absent; if the binary is cached it runs). List explicit files:
  ```
  cd mcp_server && mix deps.get
  PTC_SOAK_ITERATIONS=3000 mix test \
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
- **Package contents** (the high-value footgun check) — `mix hex.build`, unpack the
  tarball, and **assert the bundled `files:` include** `priv/prompts/`, `priv/spec/`,
  `priv/ptc_schema.json`, the generated references, and docs. Catches a `priv/*`
  omission before it ships to Hex.
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
  `benchmark.yml` uses), `LLM_DEFAULT_PROVIDER: openrouter`, `PTC_TEST_MODEL: gemini-flash-lite`.
- **`continue-on-error: true`** + every command wrapped `|| true`; `publish` does not
  `needs:` it.
- **Both surfaces:**
  1. Demo benchmarks (reuse the maintained `benchmark.yml` path):
     ```
     cd demo
     mix lisp --test --runs=${{ inputs.llm_runs || 1 }} --model=openrouter:google/gemini-3.1-flash-lite --report=tmp/lisp.md || true
     mix json --test --runs=${{ inputs.llm_runs || 1 }} --model=openrouter:google/gemini-3.1-flash-lite --report=tmp/json.md || true
     ```
     Parse `summary.passed/total`, pass-rate %, `stats.total_tokens`
     (`demo/lib/ptc_demo/lisp_test_runner.ex`).
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

### 5E. Performance — `perf` job (**deferred to Phase 2; redesign required**)

> Review correction: the original "gate on Benchee reductions for `full Lisp.run/2`"
> is **invalid**. `Lisp.run/2` runs the evaluator in a **spawned child process**
> (`sandbox.ex:141`: `Process.spawn(fn -> eval_fn.(ast, context) ... end)`), and
> Benchee only counts reductions/memory of the *benchmark* process — so it would
> capture parse+analyze + spawn/marshalling and **miss the entire eval**. A Benchee
> baseline over the full run gives false confidence.

Two metric paths (decide before building — see §8):

- **Interim (cheap, valid now):** gate Benchee **reductions on `parse` and
  `analyze` only** — those run synchronously in the benchmark process. Honest but
  partial (parse+analyze ≈ ~13% of full-run time; eval is uncovered).
- **Full path (correct gate):** the sandbox already self-measures the child —
  `get_process_memory()` at `sandbox.ex:149`, returned as `memory_bytes`/`eval_memory`.
  Add one line capturing `:erlang.process_info(self(), :reductions)` in that same child
  block, return it, and gate a small custom harness (`mix bench.check`) on **child eval
  reductions + child memory** vs a committed baseline (`bench/baselines/*.json`),
  threshold e.g. **+7%**. This is deterministic (CPU-noise-independent) and measures the
  real path.

Also: enabling `reduction_time` in `bench/lisp_throughput.exs` only helps the in-process
scenarios; wall-clock stays informational (hosted-runner noise ±20–50%). Wall-clock
trend dashboard (`github-action-benchmark` / gh-pages) is optional, out of scope for a gate.

## 6. Failure semantics (summary)

- **Red** iff: `mix test` fails, a soak assertion fails, version/changelog mismatch,
  package omits expected `priv/*`, schema/spec drift, an ExDoc warning, a broken
  **relative** doc link, or gen-doc drift. (Phase 2 adds: eval-reduction regression.)
- **Green** for: any LLM behavior (wrong answers, model/API errors, outages) and dead
  **external** URLs.

## 7. New / changed files (implementation checklist)

- `.github/workflows/release.yml` (**restructure**) — multi-job: `test`, `soak`,
  `integrity`, `docs`, `llm-smoke`, `publish` (`needs` gates only; `if:` tag-guarded).
- `.github/actions/setup-elixir/action.yml` (optional) — add `skip-babashka` input;
  optionally cache/fetch `mcp_server/deps` (or do `mix deps.get` in the soak job).
- `.lycheeignore` (new) — volatile external hosts.
- `CHANGELOG.md` — ensure a `## [<version>]` section exists per release (now gated).
- **Phase 2:** `lib/ptc_runner/sandbox.ex` (capture child reductions), `bench/lisp_throughput.exs`
  (`reduction_time` for in-process scenarios), `lib/mix/tasks/bench.check.ex` (new),
  `bench/baselines/*.json` (new).
- `docs/RELEASING.md` (optional) — root release checklist mirroring `mcp_server/RELEASING.md`.
- No model/registry change. No new runtime deps (`:recon`/`:benchee` already present);
  docs job adds the lychee action only.

## 8. Open decisions for the implementer

1. **Perf metric path** — interim parse/analyze gate, full child-reduction
   instrumentation, or skip the perf gate for the first release? (Recommend: ship Phase 1
   without perf; build the child-instrumentation version next.)
2. **`mcp-v*` tags** — should this workflow also run on the mcp_server release tag, or
   only `v*`?
3. **Perf threshold %** — start +7% on child eval reductions; tune after one baseline.
4. **mcp_server real-agentic smoke** — Phase 3: drive the *released* mcp binary with a
   real LLM via `mcp_server/bench/agentic_real_eval.exs` inside the `RELEASING.md` artifact
   smoke (currently protocol-only: `(+ 1 2)` ⇒ `user=> 3`).
5. e2e duration on gemini-3.1-flash-lite — measure once; tune `timeout-minutes`.

## 9. Phasing (suggested)

- **Phase 1 (small, high value, low ambiguity):** restructure `release.yml` with
  `test` + `soak` + `integrity` (version/changelog/package/schema/spec) + `docs`
  (ExDoc/lychee-offline/gen-doc drift) gating the publish, plus non-blocking
  `llm-smoke` (demo + e2e on gemini-3.1-flash-lite, stats-only).
- **Phase 2:** the perf gate — sandbox child-reduction instrumentation + `mix bench.check`
  + committed baseline. (Do **not** ship a Benchee-full-run gate.)
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
- (Phase 2) A seeded eval slowdown that inflates child reductions beyond threshold fails
  the `perf` job.
