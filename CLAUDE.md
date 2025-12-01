# PtcRunner - BEAM-native Programmatic Tool Calling

A BEAM-native Elixir library for Programmatic Tool Calling (PTC), enabling LLMs to write safe programs that orchestrate tools and transform data inside a sandboxed environment.

<!-- CI test: verifying Claude Code OAuth token integration -->

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

```
lib/
├── ptc_runner.ex           # Main public API
├── ptc_runner/
│   ├── dsl/                # DSL layer (JSON-based language)
│   ├── parser/             # Parser layer (DSL → AST)
│   ├── interpreter/        # Execution engine
│   └── tools/              # Tool layer (MCP integration)
test/
├── ptc_runner_test.exs     # Main tests
└── ...
docs/
├── research.md             # Research and specification notes
└── guidelines/             # Development guidelines
```

## Documentation

- **[Architecture](docs/architecture.md)** - System design, DSL specification, and API reference
- **[Development Guidelines](docs/guidelines/development-guidelines.md)** - Elixir standards
- **[Testing Guidelines](docs/guidelines/testing-guidelines.md)** - Test quality and patterns
- **[Planning Guidelines](docs/guidelines/planning-guidelines.md)** - Issue review and feature planning
- **[Research Notes](docs/research.md)** - PTC specification research

## Key Commands

- `mix test` - Run all tests
- `mix test --failed` - Re-run failed tests
- `mix format` - Format code
- `mix docs` - Generate documentation

## Architecture Overview

See **[docs/architecture.md](docs/architecture.md)** for full details.

The library has four main layers:

1. **Parser** - JSON parsing and validation
2. **Validator** - Schema validation for DSL programs
3. **Interpreter** - AST evaluation with resource limits
4. **Tool Registry** - User-defined tool functions

Programs execute in isolated BEAM processes with configurable timeout (default 1s) and memory limits (default 10MB).

## Development Reminders

- **GitHub CLI**: Use `gh` command for GitHub tasks (reading issues, PRs, creating PRs, etc.)
- **HTTP Client**: Use `Req` if HTTP is needed, never `:httpoison`, `:tesla`, or `:httpc`
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

**Core principles:**
- Test behavior, not implementation
- Strong assertions (specific values, not just shape matching)
- No `Process.sleep` for timing - use monitors or async helpers
- Each test should catch real bugs, not just increase coverage

## Planning & Issue Review

When planning features, reviewing issues, or entering plan mode:

1. **Read** `docs/guidelines/planning-guidelines.md` for the 9-point review checklist
2. **Use Explore agents** to investigate relevant code before making assumptions
3. **Check** `docs/guidelines/testing-guidelines.md` for test strategy
4. **Follow** the output format for consistent reviews
