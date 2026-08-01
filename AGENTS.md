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

## Working Style

This is a **0.x library** — expect breaking changes. Backward compatibility is
not a priority. When refactoring: delete old code rather than deprecate,
simplify aggressively, add no compatibility shims.

Explore the codebase before proposing changes — never claim a feature is
missing without evidence from the source files. When you find a problem, fix
the code and the docs together.

Code documentation must not link to `docs/plans/`; plans are disposable. Move
durable contracts into module docs, guides, or retained specifications first.

## Commit Messages

Use a concise Conventional Commit subject, e.g. `feat(mcp): add stateful
sessions`. For non-trivial commits, add a short body covering what changed and
how it was verified.

## Commands

- `mix precommit` — comprehensive local quality gate (format, compile, credo, schema, spec,
  root/Viewer tests, and launcher package/conformance/archive verification);
  run before every commit. This is intentionally much broader than the fast,
  staged-file Git pre-commit hook and can take a few minutes in a fresh worktree.
- `MIX_ENV=dev mix docs --warnings-as-errors` — ExDoc reference and rendering
  gate; run when changing user-facing documentation. Generated-doc consistency
  is a separate check inside `mix precommit`.
- `git push` — the tracked pre-push hook classifies pushed and dirty paths and
  runs the relevant root, Viewer, launcher, or documentation gates. Root
  changes run the root tests and `mix prepush` (upstream API audit, Dialyzer,
  unused-deps). Do not run `mix prepush` immediately before an ordinary push;
  invoke it directly only for diagnosis or when hooks are unavailable. PR CI
  runs the same checks as individual steps. On a resource-constrained machine,
  `PTC_PRE_PUSH_MAX_CASES=2 git push` keeps every gate enabled while reducing
  ExUnit concurrency.
- `mix test --include e2e` — E2E tests (requires `OPENROUTER_API_KEY`;
  the MCP tests also require the local server described below).
- Fix all failures before committing/pushing.

### Fresh worktree setup

Tool versions are pinned in `mise.toml`. From a new worktree, install the
toolchain and dependencies before running tests:

```bash
mise install
mix deps.get
(cd ptc_viewer && mix deps.get)
(cd ptc_runner_launcher && mix deps.get)
mix compile
```

Run `./scripts/install-hooks.sh` once per clone. Linked worktrees share the
clone's installed hook wrappers, so they do not need to reinstall them. The
first Dialyzer run in a worktree builds its local `priv/plts` cache and is
expected to be slower.

If a timing-sensitive test fails only in the full suite, rerun the exact file
and line reported by ExUnit. Do not bypass the hook; use
`PTC_PRE_PUSH_MAX_CASES=2 git push` to confirm the complete gate under lower
scheduler pressure, and fix reproducible failures.

### Local MCP E2E server

The MCP E2E tests use the stateless harness in
`test/support/mcp_go_stateless`. Its `go.mod` pins the official Go SDK
protocol implementation. Start it in one terminal:

```bash
mcp_server_dir="$(mktemp -d)"
go -C test/support/mcp_go_stateless build \
  -o "$mcp_server_dir/ptc-mcp-http-server" .
"$mcp_server_dir/ptc-mcp-http-server" -host 127.0.0.1 -port 8000
```

The credential-free interoperability test runs as a dedicated PR check and can
be run from another terminal:

```bash
PTC_TEST_MCP_2026_ENDPOINT=http://127.0.0.1:8000 \
  mix test test/ptc_runner/kernel/mcp_remote_e2e_test.exs \
    --include e2e --trace
```

The credential-free OAuth authorization/interoperability test starts the same
official SDK server behind its deterministic OAuth harness:

```bash
PTC_TEST_MCP_OAUTH=1 \
  bash test/support/mcp_go_stateless/with_server.sh \
    mix test test/ptc_runner/kernel/mcp_oauth_remote_e2e_test.exs \
      --include e2e --trace
```

The scheduled/manual model-driven test uses the same server and additionally
loads `OPENROUTER_API_KEY` and the optional `PTC_TEST_MODEL` from `.env`.

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
