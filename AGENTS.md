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

Do not copy a helper into a second module to avoid an import. For the root
project, `mix precommit` fails on duplication that is not already in
`.duplication-baseline.json`; extract the shared logic, or suppress it with a
reason when the repetition is deliberate. See the
[duplication gate](docs/maintainers/duplication-gate.md).

Work is tracked in GitHub issues. A large issue may keep its plan under
`docs/plans/` while it is implemented; plans are disposable, and the pull
request that completes one deletes it. Code documentation must not link to
`docs/plans/`; move durable contracts into module docs, guides, or retained
specifications first.

## Managed agents (PtcManager)

When `PTC_MANAGED_OPERATION_CONTEXT` is set, PtcManager started you through
Herdr. It already created and initialized this worktree through
`.ptc-manager.yml`, and its task prompt says what you may do on GitHub. Do not
run `scripts/worktree.sh` at all: `new` would nest a second worktree and `gc`
removes worktrees that PtcManager still tracks. Run expensive commands as
`$PTC_OPERATION_WRAPPER run --label <build|test|lint|verify> -- <command>`;
the pre-push hook already wraps itself.

The task prompt states a number of independent reviews. It counts cold Codex
review sessions on the finished change: `0` skips review, `1` is one
cumulative base-guarded review at the PR boundary, `2` adds one incremental
review of the draft before it, and `3` adds an adversarial `challenge` of the
finished change. Follow each session through its `followup`; never cold-review
a byte-identical tree twice.

## Independent review

When independent Codex review is required, follow the
[coding-agent review workflow](docs/maintainers/coding-agent-review.md).
Rebase onto `origin/main` before the final cumulative review and rerun the
gates on the rebased tree.

## Commits and pull requests

Use a concise Conventional Commit subject, e.g. `feat(mcp): add stateful
sessions`. For non-trivial commits, add a short body covering what changed and
how it was verified.

A pull request description has three sections and closes its issue with
`Closes #N`:

- **Summary** — what changed, as bullets.
- **Validation** — only what you ran beyond the tracked hooks and CI: focused
  test files, a live probe, a manual check. Never list test counts and never
  repeat the gates the hooks run.
- **Retrospective** — two items, each of which may be `none`: untracked
  follow-up work with a reproduction, and one repository instruction that was
  missing, wrong, or that you had to guess at. No narrative.

## GitHub issues

`ptc:ready`, `ptc:blocked`, and `ptc:needs-decision` are the only workflow
labels, and an open issue carries at most one of them. Remove the legacy
`needs-review`, `ready-for-implementation`, `needs-clarification`,
`needs-breakdown`, and `needs-maintainer-input` labels from any issue you
update. A dependency is the canonical `Blocked by #<number>` line in the issue
body. An assignee marks the issue as taken.

## Documentation

- Any edit under `docs/guides/`, including a one-line fix, starts by reading
  `.claude/skills/write-guide/SKILL.md` and ends with its checklist. The file
  path is the contract, so Claude Code, Codex, and Cursor all follow it.
- A bug fix may correct a wrong sentence in a guide but never adds one. New
  explanation goes to the reference page that owns the surface; the guide
  gets at most a link.
- Which layer owns what (module docs, guides, references, specifications,
  plans) is in `docs/maintainers/documentation.md`.

## Commands

- `mix compile` — run once after changing `mix.exs`, `mix.lock`, dependency
  sources, or a local path dependency (`ptc_runner_launcher/`, `ptc_viewer/`).
  `mix ptc ...` otherwise skips dependency validation for fast startup.
- `mix precommit` — quality gate: format, compile, cycles, Credo, duplication,
  spec, and generated-artifact staleness. It does not run the suite, Viewer,
  launcher, Dialyzer, ExDoc, or release; those run on `git push`.
- `git push` — the tracked pre-push hook runs the same gate scripts as GitHub
  Actions for the paths you changed. When a staleness check fires, run its
  write form (`mix ptc.gen_docs` for generated docs and schemas,
  `mix ptc.conformance_report --write-inventory` for
  `conformance_inventory.json`) and stage the result. Never push with
  `--no-verify`; never run `mix prepush` before an ordinary push (it is for
  static/Dialyzer diagnosis or when hooks are unavailable); never reduce test
  concurrency to make a failing push pass.
- `scripts/ci/core-tests.sh` — the core compile/test gate used by pre-push and
  CI (`CI=1`, 300 StreamData cases). `--schedulers 4` reproduces GitHub's CPU
  shape.
- `MIX_ENV=dev mix docs --warnings-as-errors` — ExDoc gate; run when changing
  user-facing documentation.
- `mix test --include e2e` — E2E tests (requires `OPENROUTER_API_KEY`). The
  optional MCP prerequisites and the `:scheduled_e2e` live probes are in the
  [development setup guide](docs/maintainers/development-setup.md).
- `mix nightly` and `mix soak` — the `:nightly` and `:soak` suites, run by
  their scheduled workflows. Run `mix nightly` locally when you touch the
  `mix ptc run` downstream path, example operator walks, Mix-process CLI
  wrappers, or the benchmark task. Never add `--trace` or `--slowest` to a
  suite you want to finish quickly: they pin `--max-cases` to 1.
- Test tags: `:e2e`, `:scheduled_e2e`, `:nightly`, `:soak`, and `:clojure` are
  excluded from `mix test` (`:clojure` needs Babashka). `:nightly` means an
  operator-path Mix/OS subprocess or an intentional multi-second wait, not an
  in-process case that takes a few hundred milliseconds. `:slow` only skips
  the pre-commit hook's scoped test run; those tests still run in pre-push
  and CI.
- Fix all failures before committing or pushing.

### Worktrees

Unless PtcManager started you (see above), never start work in the shared
checkout — create a worktree before the first edit, even for a plan-only
document. `scripts/worktree.sh new <branch> [issue]` branches from
`origin/main`, claims the issue when given (assign, comment, refuse one
already taken), and seeds and initializes the worktree. `scripts/worktree.sh
gc` removes worktrees merged into `origin/main` that are clean and a day idle
and keeps their branches; run it before creating a new one. Fresh-clone
setup, seeding, hooks, the Dialyzer PLT, the MCP E2E server, and headless
Linux VM notes are in the
[development setup guide](docs/maintainers/development-setup.md). Two rules
from it that bite mid-task: never regenerate
`priv/semantic_build_projection.json` on a feature branch, and never
hand-merge its hashes.

If a timing-sensitive test fails only in the full suite, rerun the exact file
and line ExUnit reported with the same seed. Do not bypass or throttle the
hook; fix the shared-state race or brittle deadline.

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
- `scripts/labs/` — maintainer labs (the Viewer demo journeys and the Kernel
  inspection lab). They run from a checkout with `mix` and are not shipped
  examples.
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
  test is as simple as the code it tests, delete it. Test at the boundary a
  user hits — the CLI, REPL, `doctor`, and manifest paths — not only the
  internal function; several regressions survived unit coverage until a
  command-boundary test existed.
- Adding or changing an embedded example, enum, catalog, or schema changes
  generated schemas and site pages; run `mix ptc.gen_docs` and stage the
  output with the change.
- No `Process.sleep` — use monitors or async helpers.

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
