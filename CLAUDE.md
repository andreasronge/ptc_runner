# PtcRunner - BEAM-native Programmatic Tool Calling

A BEAM-native Elixir library for Programmatic Tool Calling (PTC), enabling LLMs to write safe programs that orchestrate tools and transform data inside a sandboxed environment.

## Version 0.x - API Stability

This library is in early development. Breaking changes are expected and encouraged when they simplify the implementation or improve the developer experience. Prefer clean APIs over backwards compatibility.

## Tech Stack

- **Language**: Elixir 1.19+ / Erlang OTP 28+
- **Type**: Library (Hex package)
- **Testing**: ExUnit
- **Documentation**: ExDoc

## Quick Start

```bash
# Install dependencies
mix deps.get

# Run tests
mix test

# Format code
mix format

# Run all quality checks
mix format --check-formatted && mix compile --warnings-as-errors && mix test
```

## Project Structure

- `lib/ptc_runner/` - Core library (sandbox, context, schema)
- `lib/ptc_runner/json/` - JSON DSL implementation
- `lib/ptc_runner/lisp/` - Lisp DSL implementation
- `test/` - Tests mirroring lib structure
- `docs/` - Guide, specifications, and guidelines
- `demo/` - Separate Mix project for LLM integration testing and benchmarks

## Documentation

- **[Guide](docs/guide.md)** - System design, API reference, and getting started
- **[Development Guidelines](docs/guidelines/development-guidelines.md)** - Elixir standards
- **[Testing Guidelines](docs/guidelines/testing-guidelines.md)** - Test quality and patterns
- **[Planning Guidelines](docs/guidelines/planning-guidelines.md)** - Issue review and feature planning
- **[Issue Creation Guidelines](docs/guidelines/issue-creation-guidelines.md)** - How to create well-specified issues
- **[PR Review Guidelines](docs/guidelines/pr-review-guidelines.md)** - PR review structure and severity
- **[GitHub Workflows](docs/guidelines/github-workflows.md)** - Claude automation workflows and security gates
- **[Release Process](docs/guidelines/release-process.md)** - How to publish releases to Hex.pm

## Key Commands

- `mix test` - Run all tests
- `mix test --failed` - Re-run failed tests
- `mix format` - Format code

## Architecture Overview

See **[docs/guide.md](docs/guide.md)** for full details.

The library has four main layers:

1. **Parser** - JSON parsing and validation
2. **Validator** - Schema validation for DSL programs
3. **Interpreter** - AST evaluation with resource limits
4. **Tool Registry** - User-defined tool functions

Programs execute in isolated BEAM processes with configurable timeout (default 1s) and memory limits (default 10MB).

## Development Reminders

- **GitHub CLI**: Use `gh` command for GitHub tasks (reading issues, PRs, creating PRs, etc.)
- **Timestamps**: Always use `:utc_datetime`, never `:naive_datetime`
- **Durations**: Store as **integer milliseconds** (`duration_ms`), convert to human-readable only at display time

## Elixir Guidelines

- Elixir lists **do not support index-based access** - use `Enum.at/2`, pattern matching, or `List` functions
- Elixir variables are immutable but rebindable - capture block expression results:
  ```elixir
  # INVALID
  if condition do
    result = compute()
  end

  # VALID
  result =
    if condition do
      compute()
    end
  ```
- **Never** nest multiple modules in the same file
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate functions should end in `?` (not start with `is_`)
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

## Mix Guidelines

- Read docs with `mix help task_name` before using tasks
- Debug test failures with `mix test test/my_test.exs` or `mix test --failed`
- `mix deps.clean --all` is **almost never needed** - avoid unless you have good reason

## Testing Guidelines

See [Testing Guidelines](docs/guidelines/testing-guidelines.md) for details.

- **Skip tests** for simple, pure functions with no dependencies (e.g., single-expression transforms, basic accessors)
- **Focus tests** on integration points where multiple modules interact
- **Unit test** only when functions have complex logic, branching, or edge cases
- **Remove low-value tests** when encountered - tests that merely duplicate implementation or test trivial behavior add maintenance
  cost without catching real bugs
- Rule of thumb: if the test is as simple as the implementation, skip or remove it
- No `Process.sleep` for timing - use monitors or async helpers

## Planning & Issue Review

When planning features, reviewing issues, or entering plan mode:

1. **Read** `docs/guidelines/planning-guidelines.md` for the 9-point review checklist
2. **Use Explore agents** to investigate relevant code before making assumptions
3. **Check** `docs/guidelines/testing-guidelines.md` for test strategy
4. **Follow** the output format for consistent reviews

## Documentation Rules

- **@doc**: Required for public functions. Use doctests (`iex>`) over prose.
- **@moduledoc**: Explain module responsibility, link to relevant guides.
- **docs/*.md**: Concepts, workflows, architecture. Not API reference.
- **README.md**: Onboarding only (<200 lines). Link to HexDocs.
- **No duplication**: Cross-link between layers instead of copying.
- **Keep in sync**: Update docs when behavior changes.
