# Repository Instructions

Canonical agent instructions for this repo. `CLAUDE.md` is a symlink to this
file, so Claude Code and Codex read the same rules. Edit only this file.

PtcRunner is a BEAM-native Elixir runtime for Programmatic Tool Calling (PTC):
hosts compile immutable PTC-Lisp bundles, assemble explicit workflow and
mission environments, and execute them through a bounded owner-based Kernel.
Key docs: Kernel architecture in `docs/maintainers/kernel.md`,
documentation guidance in `docs/maintainers/documentation.md`, language
reference in `docs/ptc-lisp-specification.md`, and built-ins in
`docs/function-reference.md`.

To debug the runtime itself (not a manifest under it) — query canonical
traces or private inspection records (model exchanges, generated source,
capability payloads) non-interactively — use `mix ptc repl --profile
private-run-analysis-v2 --private-unattended`. See ["Private analysis without a
terminal"](docs/reference/repl.md#private-analysis-without-a-terminal).

## Working Style

This is a **0.x library** — expect breaking changes. Backward compatibility is
not a priority. When refactoring: delete old code rather than deprecate,
simplify aggressively, add no compatibility shims.

Explore the codebase before proposing changes — never claim a feature is
missing without evidence from the source files. When you find a problem, fix
the code and the docs together.

When independent Codex review is required, follow the focused
[coding-agent review workflow](docs/maintainers/coding-agent-review.md); do
not cold-review byte-identical trees more than once.

Do not copy a helper into a second module to avoid an import. For the root
project, `mix precommit` fails on duplication that is not already in
`.duplication-baseline.json`; extract the shared logic, or suppress it with a
reason when the repetition is deliberate. See the
[duplication gate](docs/maintainers/duplication-gate.md).

Code documentation must not link to `docs/plans/`; plans are disposable. Move
durable contracts into module docs, guides, or retained specifications first.
Remove completed plan files before submitting the final PR.

## Commit Messages

Use a concise Conventional Commit subject, e.g. `feat(mcp): add stateful
sessions`. For non-trivial commits, add a short body covering what changed and
how it was verified.

## Commands

- `mix ptc ...` — after the root application has compiled successfully once,
  the root-project command path skips dependency validation for fast startup
  while still compiling changed root sources and shipped preludes. A fresh
  build performs Mix's normal dependency validation and compilation. This
  optimization is root-only; downstream projects always retain Mix's normal
  dependency validation.
  After changing `mix.exs`, `mix.lock`, dependency sources, or either local
  path dependency (`ptc_runner_launcher/` or `ptc_viewer/`), run a normal
  `mix compile` once. Runtime manifests, host configuration, external inputs,
  and component override descriptors and sources remain live.
- `mix precommit` — local quality gate: nested-project fetch then format,
  compile, compile cycles, credo, duplication, spec, and generated-artifact
  staleness. Run it before a commit, or skip it and let `git push` be the
  CI-equivalent gate. It does not run the suite, Viewer, launcher, Dialyzer,
  ExDoc, or release — those belong to pre-push. The git pre-commit hook is
  the fast staged-file path. Do not follow `mix precommit` with
  `git push --no-verify`: pre-push still adds Dialyzer and ExDoc.
- `scripts/ci/core-tests.sh` — canonical core compile/test gate used by
  pre-push and GitHub Actions. It always sets `CI=1`, so
  StreamData runs the same 300 cases locally and remotely, while retaining all
  native schedulers by default. Use `scripts/ci/core-tests.sh --schedulers 4`
  to reproduce GitHub's current CPU shape; this does not emulate Linux.
- `MIX_ENV=dev mix docs --warnings-as-errors` — ExDoc reference and rendering
  gate; run when changing user-facing documentation. Generated-artifact
  staleness is checked separately, by both `mix precommit` and `mix prepush`.
- `git push` — the tracked pre-push hook classifies pushed and dirty paths and
  invokes the same repository-owned root, Viewer, launcher, release, and
  documentation scripts as GitHub Actions. Scheduled workflows and per-gate
  scripts select only the gates they can break, so a Nightly YAML edit does
  not run core tests. Root product changes still use the same compile/test
  flags, `CI=1` property count, static checks, Dialyzer format, and release
  verification locally and remotely.
  When one fires, run its matching write form — `mix ptc.gen_docs` for
  generated docs and schemas, or `mix ptc.conformance_report --write-inventory`
  for `conformance_inventory.json` — then stage the result. Do not run
  `mix precommit` and then a verified push of the same tree as a substitute
  for the hook, and do not run `mix prepush` immediately before an ordinary
  push; invoke `mix prepush` only for static/Dialyzer diagnosis or when hooks
  are unavailable. PR CI runs the same scripts as individual jobs. The test suite uses
  `System.schedulers_online()` concurrent cases; do not reduce that pressure
  to make a failing push pass.
- `mix test --include e2e` — E2E tests (requires `OPENROUTER_API_KEY`).
  Optional MCP tests skip unless their endpoint, binary, and token
  prerequisites are configured as described in the
  [development setup guide](docs/maintainers/development-setup.md). The comparatively
  expensive live tutorial probes use `:scheduled_e2e` instead and run only in
  scheduled or manually dispatched Integration workflows.
- `mix nightly` — the `:nightly` tests, excluded from `mix test` by default.
  The `Nightly` workflow runs them daily; run it locally when you touch the
  `mix ptc run` downstream path, example operator walks, Mix-process CLI
  wrappers, or the benchmark task. That workflow also runs the packaged
  interactive REPL PTY check (`expect` + `ptc repl`); PR `core-release`
  skips it via `PTC_SKIP_PTY_GATE`. Never add `--trace` (or
  `--slowest`, which implies it) to a suite you want to finish quickly: it
  pins `--max-cases` to 1.
- `mix soak` — the `:soak` memory-leak suite; the scheduled `Soak` workflow
  runs it. `:soak`, `:e2e`, `:scheduled_e2e`, `:nightly`, and `:clojure` are
  all excluded from `mix test` by default (`:clojure` needs Babashka).
- Two tags, two meanings, and they must not be conflated. `:nightly` means
  "operator-path Mix/OS subprocess or an intentional multi-second wait;
  excluded everywhere but the `Nightly` workflow" — apply it to those
  tests, not to in-process correctness cases that happen to take a few
  hundred milliseconds. `:slow` means only "skip on the fast pre-commit
  path" and is read solely by `.githooks/pre-commit`; those tests still run
  in pre-push and CI. Excluding `:slow` globally once dropped
  ten correctness tests from every PR to save 14.2 s.
- Fix all failures before committing/pushing.

### Worktrees

Never start work in the shared checkout — create a worktree before the first
edit, even for a plan-only document. `scripts/worktree.sh new <branch> [issue]`
branches from `origin/main`, and with an issue number claims it: assign,
comment, refuse one already taken. It also seeds and initializes the worktree:
install shared hooks, install the pinned `mise` toolchain, fetch dependencies,
and compile. Use `scripts/worktree.sh init [<dir>]` to repair or initialize an
existing checkout. `scripts/worktree.sh gc` removes worktrees merged into
`origin/main` that are clean and a day idle (`--yes` to act); it never deletes
a branch, because the branch is the artifact and the checkout is a rebuildable
cache. Run it before creating a new one.

Setting up a fresh clone or worktree — toolchain, dependencies, git hooks,
Dialyzer PLT, and the local MCP E2E server — is covered once in the
[development setup guide](docs/maintainers/development-setup.md). Two rules from it
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
  Generated `priv/preludes/kernel/agent.failure.clj` is projected from
  `PtcRunner.Kernel.LLMFailureCatalog` by `mix ptc.gen_docs`; do not edit it
  by hand.
- `docs/function-reference.md`, `docs/java-interop.md`,
  `docs/kernel-limits-reference.md`, `docs/prelude-reference.md`,
  `docs/conformance/`, `priv/preludes/kernel/agent.failure.clj`, and the site
  documentation pages under `site/guides/`, `site/installation/`, and
  `site/reference/` (plus the sidebar between the generated markers in
  `site/index.html`) are generated, as are the exit-status and profile
  diagnostic catalogs between the `BEGIN GENERATED`/`END GENERATED` markers
  in `docs/reference/cli.md`. Edit
  their owning catalogs, hand-authored shipped prelude sources, guides, or
  generator and run `mix ptc.gen_docs`. The sections shown on ptc-runner.dev
  and HexDocs both come from the documentation groups in `mix.exs`.
- `ptc_viewer/` — separate nested Mix project and canonical trace viewer. Root
  `mix precommit` does not run Viewer tests; the pre-push hook does. Format
  Viewer edits from that directory.
- `examples/` — runnable example manifests. Their tests use the `:native`
  projection while the CLI forces `:json`, so a green suite does not prove
  `mix ptc run` works.
- `bench/` — benchmarks (`mix bench.check`, `mix bench.heap`) with committed
  baselines in `bench/baselines/`.
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

## Cursor Cloud specific instructions

Durable, non-obvious notes for Cloud Agents. The toolchain, hooks, and standard
commands are already documented in `docs/maintainers/development-setup.md` and
the `## Commands` section above — read those first; this section only records
what is specific to running in the Cloud VM.

- **Toolchain lives under `mise`.** Erlang/Elixir/Java are pinned in `mise.toml`
  and managed by `mise` (installed at `~/.local/bin/mise`). Interactive shells
  activate it automatically via `~/.bashrc`, so `mix`/`elixir` are on `PATH`. In
  a non-interactive script that is *not* sourced from `~/.bashrc`, prefix
  commands with `~/.local/bin/mise exec -- …` (for example
  `~/.local/bin/mise exec -- mix test`) so the pinned tools resolve.
- **Cloud shells default to a group-writable umask.** `scripts/worktree.sh init`
  removes unsafe write permissions from existing checkout directories, but a
  child script cannot change its caller's umask. Prefix later build and test
  commands with `umask 0022;` so temporary directories also satisfy private
  destination safety checks.
- **Reinstalling deps does not rebuild.** The startup update script only runs
  `mix deps.get`; run `mix compile` yourself after pulling changes or editing
  `mix.exs`/`mix.lock`/prelude sources. The bundled native launcher's C binary
  is (re)built by `mix compile` via `elixir_make` (needs a C compiler, already
  present).
- **Smoke test the runtime offline.** `mix ptc run <project.json>` needs no
  network for the deterministic examples:
  `examples/kernel-tutorial/01-orders.ptc-project.json` and
  `examples/llm-replay/ptc-project.json`. Model-backed examples/tests need
  `OPENROUTER_API_KEY` (see the `## Commands` section).
- **The Viewer is a web app you must start explicitly.** `mix ptc viewer
  <project.json>` boots a Plug/Bandit HTTP server (not Phoenix) *inside the same
  BEAM*; by default it binds `127.0.0.1` on an OS-chosen free port and tries to
  open a browser. In the headless VM, pass `--port <PORT> --listen 127.0.0.1`
  and open the printed URL yourself. It only shows runs that already produced a
  trace, so run a project once before launching it.
- **`mix test` is the default gate (~3 min, 6800+ tests).** It excludes
  `:e2e`, `:scheduled_e2e`, `:nightly`, `:soak`, and `:clojure` by default;
  those need extra prerequisites (API key, Babashka/JVM, MCP servers) per
  `docs/maintainers/development-setup.md`.
- **latin1 locale warning is harmless.** A tmux/login shell that does not export
  a UTF-8 `LANG` makes the BEAM print a "native name encoding of latin1"
  warning. Export `LANG=C.UTF-8` (or `ELIXIR_ERL_OPTIONS="+fnu"`) for that
  shell; it does not affect correctness.

<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


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
