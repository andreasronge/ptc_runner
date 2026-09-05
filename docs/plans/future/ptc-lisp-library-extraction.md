# Extract PTC-Lisp into a separate Mix library

**Status:** future, trigger-gated; Phase 1 (boundary cleanup) is approved-shape
work that stands on its own, Phase 2 (nested-project extraction) is
trigger-gated, and a separate Git repository is explicitly not planned.
Written 2026-08-20 from a full boundary and infrastructure investigation of
the repository at that date.

The motivation is repository scale: full gates and whole-tree searches slow
down day-to-day development. The investigation found that the code boundary is
much cleaner than expected — the entire lisp→runner coupling collapses to one
dependency-inversion seam plus three misfiled modules — but also that the
performance case is weaker than the code share suggests, and that co-change
data rules out a repository split. The extraction shape that fits this repo is
the one `ptc_runner_launcher` already uses: a nested Mix project with a path
dependency locally and a Hex dependency when publishing.

## Goals

- Give the PTC-Lisp language implementation a focused compile, test, Dialyzer,
  documentation, and release boundary.
- Reduce what runner-only changes must run: today `scripts/ci/classify-changes.sh`
  maps any lisp path to `core=true`, so everything runs everything.
- Make the language embeddable without the Kernel: the extracted library needs
  only `jason`, `nimble_parsec`, and `telemetry` at runtime (the root app
  carries 7 runtime deps).
- Keep co-changes atomic: one repository, one PR, one commit for changes that
  span the language and the Kernel.

## Non-goals

- Do not split into a separate Git repository (see "Options and decision").
- Do not rename the `PtcRunner.Lisp.*` module namespace as part of the
  extraction. An app named `ptc_lisp` may ship `PtcRunner.Lisp.*` modules;
  renaming would churn 58 runner files and all docs in the same change.
- Do not move `priv/preludes/kernel/*.clj` or their compilation pipeline. The
  shipped preludes are Kernel product content that happens to be written in
  the language; only `PtcRunner.Kernel.Library` reads those files, and the
  Kernel compiles them through the library dependency.
- Do not weaken the language's conformance apparatus: the spec checksum gate,
  Babashka oracle, and `conformance_inventory.json` move with the language
  intact.

## Current state (measured 2026-08-20)

### Size

| Slice | Files | LOC |
| --- | ---: | ---: |
| `lib/ptc_runner/lisp/**` + `lisp.ex` + `sandbox.ex` | 136 | ~45,500 |
| whole `lib/` | 422 | 148,026 |
| lisp-side tests (`test/ptc_runner/lisp/**` + 4 top-level files + 5 support files) | ~142 | ~54,000 |
| whole `test/` | 337 `.exs` + 42 support | ~153,000 |
| lisp-attributable tracked files (code, tests, `docs/conformance/`, lisp `priv/` data) | ~300 of 1,227 | — |

10 of 17 `lib/mix/tasks/` tasks are purely lisp-side (`ptc.clojure_audit`,
`ptc.conformance_report`, `ptc.audit_upstream`, `ptc.smoke`,
`ptc.validate_spec`, `ptc.update_spec_checksums`, `ptc.install_babashka`,
`ptc.install_clojure`, `ptc.java_conformance`, `ptc.java_fixtures`, plus
`bench.check`).

### Coupling direction

58 non-lisp `lib/` files consume `PtcRunner.Lisp.*` — the correct direction
for a library dependency. The reverse direction is only 9 module references,
and they decompose as follows.

**One real seam.** Six of the nine references live in
`sanitize_private_error/1` in `lib/ptc_runner/lisp/eval/helpers.ex`
(~lines 330–560) plus its parallel-worker twin in
`lib/ptc_runner/lisp/eval/parallel.ex:341-344` and the facade at
`lib/ptc_runner/lisp.ex:1552`. The uniform pattern: a private prelude raised a
host-domain error; ask a Kernel authority whether the message and details are
host-authored and bounded, keep them if so, otherwise degrade to
`{:private_prelude_error, ...}`. The authorities consulted are
`Kernel.SafeMetadata`, `Kernel.LLMReplayDiagnostic`,
`Kernel.RuntimeLimitDiagnostic` (one predicate out of 632 lines),
`Kernel.LimitCatalog` (one row out of 26), and
`Kernel.AgentConfigDiagnostic`. A single host-supplied behaviour
(`retain_error?/1` + `failure_metadata/1`, defaulting to retain-nothing)
eliminates all five from the language's dependency set.

The dependency is already cyclic today: `kernel/safe_metadata.ex:382,407,412`
and `kernel/llm_replay_diagnostic.ex:5` pattern-match `PtcRunner.Lisp.Keyword`
while lisp code calls back into them.

**Misfiled leaves.**

- `Kernel.Program` (`lib/ptc_runner/kernel/program.ex`, 27 lines) is the value
  type for the Lisp `(program ...)` special form, built by
  `lisp/analyze.ex:420`. It belongs at `Lisp.Program`, together with
  `kernel/program_inspect.ex`. Other consumer: `kernel/runtime_tools.ex:21`.
- `PtcRunner.Sandbox` (`lib/ptc_runner/sandbox.ex`, 652 lines) has zero
  compile-time Kernel references, is fully callback-driven, is already
  documented under the "PTC-Lisp" ExDoc group, and is the execution substrate
  for `Lisp.run/2` (`lisp.ex:1071,1153,1292`,
  `lisp/prelude/compiler.ex:1755`). It moves into the language library.
- `PtcRunner.Utf8` (51 lines, pure) is used by 3 lisp and 5 kernel modules;
  duplicate it or let the runner call the library's copy.
- One `Kernel.MissionInventory` reference is `@moduledoc` prose
  (`lisp/introspection.ex:40`); reword.

**Implicit coupling** (all mechanical): `:ptc_runner` app-env keys in
`sandbox.ex:175-176,540-541`; `Application.app_dir(:ptc_runner, ...)` in
`lisp/java/oracle/fixtures.ex:37,41`; `[:ptc_runner, ...]` telemetry prefixes
in `lisp/java/dispatch.ex:136` and `lisp/java/oracle/runner.ex:346`;
cwd-relative compile-time loads of `priv/functions.exs` /
`priv/java_interop.exs` in `lisp/registry.ex:33-40`,
`lisp/builtin_names.ex:20-27`, `lisp/java/surface.ex:15` (inconsistent with
`fixtures.ex`, which uses `Application.app_dir`). No `Mix.env`, no
`System.get_env`, no `priv/preludes` reference anywhere under
`lib/ptc_runner/lisp/`.

### Shared infrastructure that must split

- **`mix ptc.gen_docs`** (`lib/mix/tasks/ptc.gen_docs.ex`, 1,157 lines) mixes
  provenance: `docs/function-reference.md`, `docs/java-interop.md`, and the 18
  `docs/conformance/*-audit.md` files derive from `Lisp.Registry` /
  `Lisp.Java.Surface`; the limit reference, exit-status catalog, and four
  schemas derive from Kernel modules; `docs/prelude-reference.md` needs both
  sides at once (`Kernel.Library` sources → `Kernel.compile_bundle` →
  `Lisp.Prelude.Export`) and stays runner-side with the library as a dep.
- **Conformance apparatus** moves wholesale — spec + `priv/spec/checksums.ex`
  gate, Babashka oracle (`lisp/clojure_validator.ex`,
  `lisp/java/oracle/`), `conformance_inventory.json`,
  `mix ptc.conformance_report`. Pure language behavior, zero Kernel
  references. One wart to fix on the way: the report task loads
  `test/support/lisp_conformance_cases/manual.ex` (8,156 LOC) from `lib/`
  code (`ptc.conformance_report.ex:22`).
- **`test/support/`** splits as 5 lisp-only files (~8,942 LOC), 11
  kernel-only, and 8 small genuinely shared helpers that get duplicated. The
  extracted project's `test_helper.exs` must keep
  `max_cases: System.schedulers_online()` (that setting exists for
  `Sandbox.execute/3` starvation) and the `:clojure` exclusion.
- **`test/ptc_runner/kernel/agent_library_test.exs`** (4,263 LOC, the largest
  kernel test) exercises the shipped preludes end-to-end; it stays
  runner-side and becomes the cross-package integration test, which is the
  correct place for it. 22 of 147 kernel test files reference
  `PtcRunner.Lisp.*` and stay runner-side likewise.
- **`priv/semantic_build_projection.json`**: 127 of 322 per-file source
  hashes are lisp files. After extraction the library collapses into one
  `runtime_dependencies` lock entry with a `content_identity` — a deliberate
  coarsening of semantic-revision forensics for language changes.
  `kernel/semantic_revision.ex:17` also aliases `Lisp.Eval.Context` (same
  inversion seam). Regenerate on main only, per the existing governance rule.
- **Bench**: `bench/lisp_throughput.exs`, `bench/lisp_profile.exs`,
  `bench/lisp_concurrency.exs`, and `mix bench.check` move (`bench.check`
  already compiles preludes via `Lisp.Prelude.Compiler` directly, not
  `Kernel.compile_bundle`). `mix bench.heap` stays runner-side and keeps its
  three `lisp_*` baseline rows through the dep.
- **ExDoc / packaging**: the "PTC-Lisp" module group (9 entries incl.
  `PtcRunner.Sandbox`) becomes the library's HexDocs; the root `package()`
  files list ships 6 lisp-owned `priv/` data files that move; the
  `groups_for_extras` "Reference" regex mixes both sides and needs splitting;
  6 of 7 `test_coverage.ignore_modules` entries are lisp modules.

### Honest performance accounting

The suite profile is ~171 s = ~32 s async + ~139 s sync, and the sync 81% is
entirely runner-side (CommandEngine, MCP transports, Mix tasks). Lisp tests are 131 of 133 `async: true` and
live in the cheap async phase, so extraction shaves only ~15–25 s of suite
wall time, not the ~30% its LOC share suggests. Warm incremental `mix compile`
is ~4.6 s; the edit loop is not the problem.

Where extraction does pay:

- **Dialyzer** (the pre-push tail): lisp beams move from analyzed-every-run
  into the cached PLT. Likely the single biggest recurring win.
- **Gate selection**: in August 2026, ~77% of file-bearing commits touched no
  lisp code; with a project boundary those skip ~137 lisp test files, the
  spec gate, conformance inventory, and lisp doc audits. Lisp-only pushes
  skip the slow sync runner suite locally.
- **Cold compiles / CI / `mix compile --force`**: ~30% less root code.
- **Search surface**: ~24% fewer tracked files — but this fully materializes
  only with a separate repository; a nested project still sits in the same
  tree, and search scoping to `lib/ptc_runner/lisp/` achieves most of it
  today. Search pain must not drive the architecture decision.

### Co-change data (rules out a repository split)

From `git log` over `lib/` and `test/` (merge commits excluded):

- Since 2026-05-01: 327 lisp-touching commits, of which 216 (66%) also
  touched non-lisp code; 778 commits touched no lisp code.
- August 2026 alone: 61 lisp-touching of ~493 file-bearing commits (12%,
  clearly cooling), and 50 of those 61 touched both sides.

In a 0.x codebase that deletes rather than deprecates, a separate repository
turns every co-change into a two-repo, publish-then-bump sequence — Hex
forbids path dependencies in published packages, so the runner change that
needs a language change cannot even compile in CI until the language release
exists. That overhead lands exactly on the boundary-moving changes that are
hardest to begin with.

## Options and decision

1. **Separate Git repository + Hex package** — rejected while the co-change
   rate stays at this level and the language spec still moves with the
   Kernel. Revisit only if lisp-only development becomes common again *and*
   the boundary has been stable across several releases; current data shows
   the opposite on both counts.
2. **Nested Mix project in this repository** (`ptc_lisp/` beside
   `ptc_runner_launcher/` and `ptc_viewer/`): path dependency locally,
   conditional Hex dependency for publishing — exactly the launcher pattern
   at `mix.exs:163-165`. Own test suite, own PLT, own pre-push lane selected
   by the existing path classification. Atomic co-changes preserved. This is
   the chosen extraction shape (Phase 2).
3. **Boundary cleanup without extraction** (Phase 1) — worth doing
   unconditionally: it removes a real dependency cycle, and afterwards
   `classify-changes.sh` can exploit the asymmetry (runner-only changes
   cannot break lisp tests) even without any project split.

Known cost of the nested-project shape: the `mix ptc` root fast-start path
does not recompile path dependencies, so lisp-implementation edits require a
normal `mix compile` first (same as launcher/viewer edits today). Acceptable
at the current ~12% lisp commit share; real friction during a lisp-heavy
stretch.

## Phase 1 — boundary cleanup (no extraction required)

Each lands independently and improves the architecture on its own:

1. Define a host-diagnostics behaviour for private-error retention
   (`retain_error?/1` + `failure_metadata/1`, default retain-nothing),
   injected via the eval context. Kernel implements it with
   `SafeMetadata` / `LLMReplayDiagnostic` / `RuntimeLimitDiagnostic` /
   `LimitCatalog` / `AgentConfigDiagnostic`. This removes all five aliases
   from `lisp/eval/helpers.ex`, `lisp/eval/parallel.ex`, and `lisp.ex`, and
   breaks the existing `SafeMetadata`↔`Lisp.Keyword` cycle.
2. Move `Kernel.Program` (+ `program_inspect.ex`) to `Lisp.Program`; update
   `lisp/analyze.ex`, `lisp.ex`, `kernel/runtime_tools.ex`.
3. Move `PtcRunner.Sandbox` under the Lisp namespace (or into
   `lib/ptc_runner/lisp/`); keep the `:ptc_runner` app-env keys until Phase 2.
4. Fix the cwd-relative compile-time `priv/` loads in `lisp/registry.ex`,
   `lisp/builtin_names.ex`, `lisp/java/surface.ex` to `__DIR__`- or
   `app_dir`-relative; decide `Utf8`'s home; reword the `MissionInventory`
   prose reference.
5. Teach `scripts/ci/classify-changes.sh` the asymmetry: runner-only changes
   skip the lisp test tree and lisp doc/conformance gates.

Exit criterion: zero references from `lib/ptc_runner/lisp/**` (plus the moved
`sandbox.ex` and `lisp.ex`) to any module outside the lisp namespace.

## Phase 2 — nested-project extraction (trigger-gated)

Trigger: Phase 1 complete, and either the Dialyzer/pre-push tail or CI cold
compile is again the measured bottleneck, or an external embedding consumer
for the language exists.

Mechanical move once Phase 1 holds:

- `lib/ptc_runner/lisp/**`, `lisp.ex`, `sandbox.ex` → `ptc_lisp/lib/`.
- `test/ptc_runner/lisp/**`, the 4 lisp top-level test files (`lisp_test`,
  `lisp_telemetry_test`, `context_test`, `sandbox_test`), and the 5 lisp
  support files → `ptc_lisp/test/`; duplicate the 8 shared helpers.
- The 10 lisp-only Mix tasks, the lisp `priv/` data files (`functions.exs`,
  `function_audit.exs`, `java_interop*`, `java_oracle_versions.exs`,
  `priv/spec/`), the three lisp bench scripts + `bench.check` +
  `bench/baselines/lisp_eval.json`, and the lisp docs (specification,
  clojure-conformance-gaps, function-reference, java-interop, signature
  docs, `docs/conformance/`) → `ptc_lisp/`.
- Split `ptc.gen_docs` along the provenance table above;
  `prelude-reference.md` generation stays runner-side.
- Rename `:ptc_runner` app-env keys, `app_dir` atoms, and telemetry prefixes
  to `:ptc_lisp` (breaking; acceptable in 0.x — call it out in the
  changelog).
- Root `mix.exs`: `{:ptc_lisp, "~> 0.x"}` with the launcher-style
  path/Hex conditional; update `package()` files, ExDoc groups/extras, and
  `test_coverage.ignore_modules`.
- Gates: add a `ptc_lisp` lane to the pre-push classification and CI jobs,
  mirroring the Viewer/launcher pattern; regenerate
  `priv/semantic_build_projection.json` on main.

## Verification

- Phase 1: `grep -r 'PtcRunner\.\(Kernel\|Sandbox\|Utf8\)' lib/ptc_runner/lisp lib/ptc_runner/lisp.ex`
  returns nothing (after the Sandbox move, adjust for its new home); full
  suite green; Dialyzer clean.
- Phase 2: root suite green with the path dep; `ptc_lisp` suite green in
  isolation; `mix ptc.gen_docs --check` and
  `mix ptc.conformance_report --check-inventory` green in their new homes;
  `mix hex.build` for both packages ships the right files; the
  `agent_library_test.exs` integration path still compiles the shipped
  preludes through the dependency.
