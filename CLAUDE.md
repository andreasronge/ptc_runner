# PtcRunner - BEAM-native Programmatic Tool Calling

A BEAM-native Elixir library for Programmatic Tool Calling (PTC), enabling LLMs to write safe programs that orchestrate tools and transform data inside a sandboxed environment.

- **SubAgent API**: See `docs/guides/` (start with `subagent-getting-started.md`)
- **PTC-Lisp**: See `docs/ptc-lisp-specification.md` for language reference
- **E2E tests**: `mix test --include e2e` (requires `OPENROUTER_API_KEY`)

This is a **0.x library** — expect breaking changes. Backward compatibility is not a priority. When refactoring:
- Delete old code rather than deprecate
- Simplify aggressively
- Don't add compatibility shims

Before making changes, explore the codebase first: 1) What existing code already handles this? 2) What's the current state of the relevant modules? 3) What patterns do similar features follow? Summarize findings before proposing changes. Never claim features are missing without evidence from the source files.

When you find issues, fix both the code and the docs together.

## Tech Stack

- **Language**: Elixir 1.19+ / Erlang OTP 28+
- **Type**: Library (Hex package)
- **Testing**: ExUnit
- **Documentation**: ExDoc

## Commands

```bash
mix deps.get                    # Install dependencies
mix test                        # Run tests (--failed to re-run failures)
mix format                      # Format code
mix credo --strict              # Lint
mix dialyzer                    # Type checking
mix precommit                   # Run before pushing (format + compile + credo + dialyzer + test)
```

Full quality check: `mix format --check-formatted && mix compile --warnings-as-errors && mix test`

Always run `mix precommit` before `git push`. If it fails, fix all issues before pushing.

## Project Structure

- `docs/` - Specifications and guidelines
- `demo/` - LLM integration testing and benchmarks (see `demo/README.md` for CLI options)
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

**Single-shot vs Multi-turn:**
- **Single-shot**: Expression result is the answer. No `return` form needed.
- **Multi-turn**: Loop continues until `(return value)` or `(fail reason)` is called.

## Guidelines

- **[Testing Guidelines](docs/guidelines/testing-guidelines.md)** | **[Planning Guidelines](docs/guidelines/planning-guidelines.md)** | **[GitHub Workflows](docs/guidelines/github-workflows.md)** | **[Documentation Guidelines](docs/guidelines/documentation-guidelines.md)**
- **[PTC-Lisp Specification](docs/ptc-lisp-specification.md)**

### Elixir/Mix

- Use `gh` for GitHub tasks (issues, PRs)
- Timestamps: `:utc_datetime`, never `:naive_datetime`
- Durations: integer milliseconds (`duration_ms`)
- Lists don't support index access - use `Enum.at/2` or pattern matching
- Capture block results: `result = if condition do ... end`
- Never nest multiple modules in one file
- No `String.to_atom/1` on user input (memory leak)
- Predicates end in `?` (not `is_` prefix)
- `mix deps.clean --all` rarely needed - avoid it
- When working with PTC-Lisp, check Clojure conformance
- When working with LLM integrations, verify model IDs are current and check .env overrides

### Code Quality

- When fixing dialyzer or Credo issues, always re-run the tool after changes to verify the fix. Never assume fixes are correct without verification.
- Run `mix precommit` to catch all issues before committing.

### Testing

See [Testing Guidelines](docs/guidelines/testing-guidelines.md) for full details.

- **Bug fix workflow**: Always write a failing integration test that reproduces the bug BEFORE fixing it.
- **No low-value unit tests**: Do not write unit tests for trivial pure functions or tests that just mirror the implementation. If a test is as simple as the code it tests, delete it. Prefer integration tests that exercise real behavior.
- No `Process.sleep` - use monitors or async helpers
- Examples, benchmarks, and test prompts should be generic and domain-independent. Do not overlap with existing test/benchmark domains unless explicitly asked.

### Documentation

- **@doc**: Required for public functions. Use doctests (`iex>`) over prose.
- **Doctests**: Use full module paths (e.g., `PtcRunner.Module.func()` not `Module.func()`). Ensure test files include `doctest ModuleName`.
- **@moduledoc**: Explain module responsibility, link to relevant guides.
- **docs/*.md**: Concepts, workflows, architecture. Not API reference.
- **README.md**: Onboarding only (<200 lines). Link to HexDocs.
- Cross-link between layers instead of duplicating content.
