# PtcRunner - BEAM-native Programmatic Tool Calling

A BEAM-native Elixir library for Programmatic Tool Calling (PTC), enabling LLMs to write safe programs that orchestrate tools and transform data inside a sandboxed environment.

- **SubAgent API**: See `docs/ptc_agents/specification.md` and `docs/guides/` (start with `subagent-getting-started.md`)
- **Core API**: `docs/guide.md` - stable, well-tested
- **E2E tests**: `mix test --include e2e` (requires `OPENROUTER_API_KEY`)

When you find issues, fix both the code and the docs together.

## Tech Stack

- **Language**: Elixir 1.19+ / Erlang OTP 28+
- **Type**: Library (Hex package)
- **Testing**: ExUnit
- **Documentation**: ExDoc

## Quick Start

```bash
mix deps.get                    # Install dependencies
mix test                        # Run tests (--failed to re-run failures)
mix format                      # Format code
# Full quality check:
mix format --check-formatted && mix compile --warnings-as-errors && mix test
```

## Project Structure

- `lib/ptc_runner/` - Core library (sandbox, context, schema)
- `lib/ptc_runner/json/` - JSON DSL implementation
- `lib/ptc_runner/lisp/` - Lisp DSL implementation
- `test/` - Tests mirroring lib structure
- `docs/` - Current API guide and guidelines
- `docs/guides/` - SubAgent guides and tutorials
- `demo/` - LLM integration testing and benchmarks
- `priv/prompts/` - LLM prompt templates (compile-time; recompile after changes)

## Documentation

- **[Guide](docs/guide.md)** - System design and API reference
- **[Testing Guidelines](docs/guidelines/testing-guidelines.md)** - Test quality and patterns
- **[Planning Guidelines](docs/guidelines/planning-guidelines.md)** - Issue review and feature planning
- **[Roadmap Guidelines](docs/guidelines/roadmap-guidelines.md)** - Multi-issue feature planning
- **[GitHub Workflows](docs/guidelines/github-workflows.md)** - PM workflow, epics, and automation
- **[Documentation Guidelines](docs/guidelines/documentation-guidelines.md)** - Writing docs and guides

## Architecture Overview

See **[docs/guide.md](docs/guide.md)** for full details.

The library has four main layers:

1. **Parser** - JSON parsing and validation
2. **Validator** - Schema validation for DSL programs
3. **Interpreter** - AST evaluation with resource limits
4. **Tool Registry** - User-defined tool functions

Programs execute in isolated BEAM processes with configurable timeout (default 1s) and memory limits (default 10MB).

## Elixir/Mix Guidelines

- Use `gh` for GitHub tasks (issues, PRs)
- Timestamps: `:utc_datetime`, never `:naive_datetime`
- Durations: integer milliseconds (`duration_ms`)
- Lists don't support index access - use `Enum.at/2` or pattern matching
- Capture block results: `result = if condition do ... end`
- Never nest multiple modules in one file
- No `String.to_atom/1` on user input (memory leak)
- Predicates end in `?` (not `is_` prefix)
- `mix deps.clean --all` rarely needed - avoid it

## Testing Guidelines

See [Testing Guidelines](docs/guidelines/testing-guidelines.md) for full details.

- Skip tests for trivial pure functions; focus on integration points
- Remove low-value tests that duplicate implementation
- Rule: if test is as simple as implementation, skip it
- No `Process.sleep` - use monitors or async helpers

## Documentation Rules

- **@doc**: Required for public functions. Use doctests (`iex>`) over prose.
- **Doctests**: Use full module paths (e.g., `PtcRunner.Module.func()` not `Module.func()`). Ensure test files include `doctest ModuleName` to validate examples.
- **@moduledoc**: Explain module responsibility, link to relevant guides.
- **docs/*.md**: Concepts, workflows, architecture. Not API reference.
- **README.md**: Onboarding only (<200 lines). Link to HexDocs.
- **No duplication**: Cross-link between layers instead of copying.
- **Keep in sync**: Update docs when behavior changes.
