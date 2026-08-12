# Repository Instructions

Canonical agent instructions for this repo. `CLAUDE.md` is a symlink to this
file, so Claude Code and Codex read the same rules. Edit only this file.

PtcRunner is a BEAM-native Elixir runtime for Programmatic Tool Calling (PTC):
hosts compile immutable PTC-Lisp bundles, assemble explicit workflow and
mission environments, and execute them through a bounded owner-based Kernel.
Key docs: Kernel architecture in `docs/guides/kernel-maintainer.md`,
documentation guidance in `docs/guides/documentation-guidelines.md`, language
reference in `docs/ptc-lisp-specification.md`, and built-ins in
`docs/function-reference.md`.

To debug the runtime itself (not a manifest under it) — query canonical
traces or private inspection records (model exchanges, generated source,
capability payloads) non-interactively — use `mix ptc repl --profile
inspection-analysis-v2 --private-unattended`. See ["Private analysis without a
terminal"](docs/guides/kernel-repl.md#private-analysis-without-a-terminal).

## Working Style

This is a **0.x library** — expect breaking changes. Backward compatibility is
not a priority. When refactoring: delete old code rather than deprecate,
simplify aggressively, add no compatibility shims.

Explore the codebase before proposing changes — never claim a feature is
missing without evidence from the source files. When you find a problem, fix
the code and the docs together.

When independent Codex review is required, follow the focused
[coding-agent review workflow](docs/guides/coding-agent-review-workflow.md); do
not cold-review byte-identical trees more than once.

Do not copy a helper into a second module to avoid an import. For the root
project, `mix precommit` fails on duplication that is not already in
`.duplication-baseline.json`; extract the shared logic, or suppress it with a
reason when the repetition is deliberate. See the
[duplication gate](docs/guides/duplication-gate.md).

Code documentation must not link to `docs/plans/`; plans are disposable. Move
durable contracts into module docs, guides, or retained specifications first.

## Commit Messages

Use a concise Conventional Commit subject, e.g. `feat(mcp): add stateful
sessions`. For non-trivial commits, add a short body covering what changed and
how it was verified.

## Commands

- `mix precommit` — comprehensive local quality gate (format, compile, compile
  cycles, stable-CLI callers, credo, duplication, spec, generated-artifact
  staleness, root/Viewer/launcher tests, core-package and standalone release
  verification); run before every commit. Much broader than the fast,
  staged-file Git pre-commit hook; takes a few minutes in a fresh worktree.
- `MIX_ENV=dev mix docs --warnings-as-errors` — ExDoc reference and rendering
  gate; run when changing user-facing documentation. Generated-artifact
  staleness is checked separately, by both `mix precommit` and `mix prepush`.
- `git push` — the tracked pre-push hook classifies pushed and dirty paths and
  runs the relevant root, Viewer, launcher, or documentation gates. Root
  changes run the root tests and `mix prepush` (credo, generated-artifact
  staleness, upstream API audit, Dialyzer, unused-deps). Credo and the staleness
  checks are also in `precommit`, and are repeated here because an ordinary push
  does not run `precommit` — without them a `lib/` edit can clear every local
  gate and still fail CI on an artifact you were never prompted to regenerate.
  When one fires, run its matching write form — `mix ptc.gen_docs` for
  generated docs and schemas, or `mix ptc.conformance_report --write-inventory`
  for `conformance_inventory.json` — then stage the result. Do not run
  `mix prepush` immediately before an ordinary push;
  invoke it directly only for diagnosis or when hooks are unavailable. PR CI
  runs the same checks as individual steps. The test suite uses
  `System.schedulers_online()` concurrent cases; do not reduce that pressure
  to make a failing push pass.
- `mix test --include e2e` — E2E tests (requires `OPENROUTER_API_KEY`;
  the MCP tests also require the local server in the
  [development setup guide](docs/development-setup.md)).
- `mix nightly` — the `:nightly` tests, excluded from `mix test` by default.
  The `Nightly` workflow runs them daily; run it locally when you touch the
  `mix ptc run` downstream path or the benchmark task. Never add `--trace` (or
  `--slowest`, which implies it) to a suite you want to finish quickly: it
  pins `--max-cases` to 1.
- `mix soak` — the `:soak` memory-leak suite; the scheduled `Soak` workflow
  runs it. `:soak`, `:e2e`, `:nightly`, and `:clojure` are all excluded from
  `mix test` by default (`:clojure` needs Babashka).
- Two tags, two meanings, and they must not be conflated. `:nightly` means
  "costs tens of seconds; excluded everywhere but the `Nightly` workflow" —
  apply it sparingly, because it removes a test from every PR gate. `:slow`
  means only "skip on the fast pre-commit path" and is read solely by
  `.githooks/pre-commit`; those tests still run in `precommit`, pre-push, and
  CI. Excluding `:slow` globally once dropped ten correctness tests from every
  PR to save 14.2 s.
- Fix all failures before committing/pushing.

### Worktrees

Never start work in the shared checkout — create a worktree before the first
edit, even for a plan-only document. `scripts/worktree.sh new <branch> [issue]`
branches from `origin/main`, and with an issue number claims it: assign,
comment, refuse one already taken. `scripts/worktree.sh gc` removes worktrees
merged into `origin/main` that are clean and a day idle (`--yes` to act); it
never deletes a branch, because the branch is the artifact and the checkout is
a rebuildable cache. Run it before creating a new one.

Setting up a fresh clone or worktree — toolchain, dependencies, git hooks,
Dialyzer PLT, and the local MCP E2E server — is covered once in the
[development setup guide](docs/development-setup.md). Two rules from it
that bite mid-task: never regenerate `priv/semantic_build_projection.json` on a
feature branch, and never hand-merge its hashes.

If a timing-sensitive test fails only in the full suite, rerun the exact file
and line reported by ExUnit. Do not bypass or throttle the hook; reproduce the
reported seed and fix shared-state races, brittle deadlines, or other
load-sensitive failures.

## Project Structure

- `lib/ptc_runner/` — the library (`kernel/`, `lisp/`, `sandbox.ex`, …).
- `ptc_runner_launcher/` — optional macOS/Linux MCP stdio launcher companion.
- `docs/` — specifications, guides, and implementation records.
  `priv/preludes/kernel/` — shipped Lisp libraries; recompile after editing.
- `docs/function-reference.md`, `docs/java-interop.md`, and `docs/conformance/`
  are generated. Edit their `priv/*.exs` sources and run `mix ptc.gen_docs`.
- `ptc_viewer/` — separate nested Mix project and canonical trace viewer. Root
  `mix precommit` runs its tests but not its formatter; format Viewer edits
  from that directory.
- `examples/` — runnable example manifests. Their tests use the `:native`
  projection while the CLI forces `:json`, so a green suite does not prove
  `mix ptc run` works.
- `bench/` — benchmarks (`mix bench.check`, `mix bench.heap`) with committed
  baselines in `bench/baselines/`.
- `repo-analyst/` — the repo-analysis manifest suite PtcRunner dogfoods; its
  host configs and fixtures are `repo-analyst*.json` at the repo root.

## Conventions

- Timestamps: `:utc_datetime`, never `:naive_datetime`. Durations: integer
  milliseconds (`duration_ms`).
- Never nest multiple modules in one file. Avoid `mix deps.clean --all`.
- After fixing a dialyzer/Credo issue, re-run the tool to verify — never assume.
- Owner-process state (Agent, GenServer) is mutated only through single
  atomic operations (`Agent.get_and_update/2`, or run the work inside the
  owner). A separate `Agent.get` followed by `Agent.update` on the same
  agent is a read-modify-write race and review-blocking.
- Use `gh` for GitHub tasks. When touching LLM integrations, verify model IDs
  are current and check `.env` overrides.

## PTC-Lisp Changes

Clojure compatibility is the default, but sandbox safety and recoverable signal
values take precedence for Clojure-named functions where Clojure would raise;
Java-named dot methods keep Java semantics. See
`docs/clojure-conformance-gaps.md` for the DIV-* rationale.

## Prompts (domain-blind)

System prompts, planner prompts, and agent configurations **must not** contain
hints about test data, benchmark domains, or expected answer patterns. The
orchestration layer must work across unrelated domains without prompt changes.
Tool descriptions *may* reference their own domain. Benchmarks and test prompts
must be generic and not overlap existing domains unless asked.

## Testing

- Bug fixes: write a failing test that reproduces the bug **before** fixing it.
- Prefer integration tests over unit tests that mirror the implementation; if a
  test is as simple as the code it tests, delete it.
- No `Process.sleep` — use monitors or async helpers.

<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

[usage_rules usage rules](deps/usage_rules/usage-rules.md)
<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
[usage_rules:elixir usage rules](deps/usage_rules/usage-rules/elixir.md)
<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
[usage_rules:otp usage rules](deps/usage_rules/usage-rules/otp.md)
<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
