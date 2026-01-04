# PtcRunner - BEAM-native Programmatic Tool Calling

A BEAM-native Elixir library for Programmatic Tool Calling (PTC), enabling LLMs to write safe programs that orchestrate tools and transform data inside a sandboxed environment.

- **SubAgent API**: See `docs/guides/` (start with `subagent-getting-started.md`)
- **PTC-Lisp**: See `docs/ptc-lisp-specification.md` for language reference
- **E2E tests**: `mix test --include e2e` (requires `OPENROUTER_API_KEY`)

When you find issues, fix both the code and the docs together.

This is a **0.x library** — expect breaking changes. Backward compatibility is not a priority. When refactoring:
- Delete old code rather than deprecate
- Simplify aggressively
- Don't add compatibility shims

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

- `docs/` - Specifications and guidelines
- `demo/` - LLM integration testing and benchmarks
- `priv/prompts/` - LLM prompt templates (compile-time; recompile after changes)

## Architecture

```
lib/ptc_runner/
├── sub_agent/        # Loop logic, prompt generation, signatures
├── lisp/             # Parser, analyzer, interpreter
├── json/             # JSON DSL operations
├── sandbox.ex        # Isolated BEAM process execution
├── step.ex           # Result type for all executions
├── tool.ex           # Tool normalization
├── context.ex        # ctx/memory/tools container
├── schema.ex         # JSON Schema validation
└── tracer.ex         # Execution tracing/observability
```

**Flow**: `SubAgent.run/2` → LLM generates PTC-Lisp → `Lisp.run/2` → `Sandbox.execute/3` → `Eval.eval/5`

Programs execute in isolated BEAM processes with timeout (1s) and memory limits (10MB).

### Key Flows

**Single-shot vs Multi-turn:**
- **Single-shot**: Expression result is the answer. No `return` form needed.
- **Multi-turn**: Loop continues until `(return value)` or `(fail reason)` is called.

**Loop termination** (in `Loop`, detected by `ResponseHandler.contains_call?`):
- `(return value)` → loop ends with `{:ok, step}`
- `(fail reason)` → loop ends with `{:error, step}`
- Neither → loop continues, `step.return` sent as feedback to LLM

**Memory contract** (in `Lisp.run/2`, via `apply_memory_contract/3`):
Note: `:return` KEY in a map ≠ `(return ...)` CALL. The key controls feedback; the call terminates the loop.

- Loop termination: `lib/ptc_runner/sub_agent/loop.ex`
- Memory contract: `lib/ptc_runner/lisp.ex` (`apply_memory_contract/3`)
- Memory access: `lib/ptc_runner/lisp/eval.ex` (`memory/key` syntax)

## Documentation

- **[PTC-Lisp Specification](docs/ptc-lisp-specification.md)** - Language reference
- **[Testing Guidelines](docs/guidelines/testing-guidelines.md)** - Test quality and patterns
- **[Planning Guidelines](docs/guidelines/planning-guidelines.md)** - Issue review and feature planning
- **[Roadmap Guidelines](docs/guidelines/roadmap-guidelines.md)** - Multi-issue feature planning
- **[GitHub Workflows](docs/guidelines/github-workflows.md)** - PM workflow, epics, and automation
- **[Documentation Guidelines](docs/guidelines/documentation-guidelines.md)** - Writing docs and guides

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
