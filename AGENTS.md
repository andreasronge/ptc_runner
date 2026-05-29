# Repository Instructions

Canonical agent instructions for this repo. `CLAUDE.md` is a symlink to this
file, so Claude Code and Codex read the same rules. Edit only this file.

PtcRunner is a BEAM-native Elixir library for Programmatic Tool Calling (PTC):
LLMs write safe PTC-Lisp programs that orchestrate tools and transform data in
a sandboxed BEAM process (1s timeout, 10MB memory). Key docs: SubAgent guides
in `docs/guides/`, language reference in `docs/ptc-lisp-specification.md`,
built-ins in `docs/function-reference.md`.

## Working Style

This is a **0.x library** — expect breaking changes. Backward compatibility is
not a priority. When refactoring: delete old code rather than deprecate,
simplify aggressively, add no compatibility shims.

Explore the codebase before proposing changes — never claim a feature is
missing without evidence from the source files. When you find a problem, fix
the code and the docs together.

## Commit Messages

Use a concise Conventional Commit subject, e.g. `feat(mcp): add stateful
sessions`. For non-trivial commits, add a short body covering what changed and
how it was verified.

## Commands

- `mix precommit` — fast quality gate (format, compile, credo, schema, spec,
  tests); run before every commit.
- `mix prepush` — slower checks (dialyzer, unused-deps) before `git push`; CI
  runs these on every PR regardless.
- `mix test --include e2e` — E2E tests (requires `OPENROUTER_API_KEY`).
- Fix all failures before committing/pushing.

## Project Structure

- `lib/ptc_runner/` — the library (`sub_agent/`, `lisp/`, `sandbox.ex`, …).
- `docs/` — specs and guidelines. `priv/prompts/` — LLM prompt templates,
  **compiled in; recompile after editing**.
- Sibling Mix projects: `mcp_server/` (`ptc_runner_mcp` on Hex, stdio MCP
  server), `ptc_viewer/` (trace viewer), `demo/` (LLM benchmarks).

## Conventions

- Timestamps: `:utc_datetime`, never `:naive_datetime`. Durations: integer
  milliseconds (`duration_ms`).
- Never nest multiple modules in one file. Avoid `mix deps.clean --all`.
- After fixing a dialyzer/Credo issue, re-run the tool to verify — never assume.
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
