# API Refactor Plan: Multi-Language Support

**Status:** Draft
**Breaking Change:** Yes (v0.3.0 → v0.4.0)

---

## Overview

Refactor PtcRunner's public API to support multiple DSL languages (JSON and Lisp) through separate namespaced modules while sharing common infrastructure.

### New API

```elixir
# JSON DSL (refactored from current API)
PtcRunner.Json.run(source, opts)
PtcRunner.Json.run!(source, opts)

# PTC-Lisp (new)
PtcRunner.Lisp.run(source, opts)
PtcRunner.Lisp.run!(source, opts)
```

### Deprecation

```elixir
# Old API (deprecated, delegates to Json)
PtcRunner.run(source, opts)   # → PtcRunner.Json.run/2
PtcRunner.run!(source, opts)  # → PtcRunner.Json.run!/2
```

---

## Goals

1. **Clean separation**: Each language has its own parser, validator, and interpreter
2. **Shared infrastructure**: Sandbox, Context, and metrics are reused
3. **Consistent API**: Both languages use identical options and return types
4. **Maintainability**: Easy to add future languages without changing core

---

## New Module Structure

```
lib/
├── ptc_runner.ex                    # Deprecated entry point (delegates to Json)
├── ptc_runner/
│   ├── sandbox.ex                   # Shared - unchanged
│   ├── context.ex                   # Shared - extended for memory/
│   ├── schema.ex                    # Shared - operation definitions
│   │
│   ├── json.ex                      # Public: PtcRunner.Json.run/2
│   ├── json/
│   │   ├── parser.ex                # JSON → AST (moved from parser.ex)
│   │   ├── validator.ex             # AST validation (moved)
│   │   ├── interpreter.ex           # AST evaluation (moved)
│   │   └── operations.ex            # Built-in ops (moved)
│   │
│   ├── lisp.ex                      # Public: PtcRunner.Lisp.run/2
│   └── lisp/
│       ├── parser.ex                # NimbleParsec → RawAST
│       ├── analyzer.ex              # RawAST → CoreAST
│       ├── interpreter.ex           # CoreAST evaluation
│       └── builtins.ex              # Lisp built-in functions
```

---

## Implementation Phases

### Phase 1: Prepare JSON Namespace

Move existing code into `PtcRunner.Json` namespace without changing behavior.

#### 1.1 Create `PtcRunner.Json` module

```elixir
# lib/ptc_runner/json.ex
defmodule PtcRunner.Json do
  @moduledoc """
  Execute PTC programs written in JSON DSL.
  """

  alias PtcRunner.Context
  alias PtcRunner.Json.Parser
  alias PtcRunner.Json.Validator
  alias PtcRunner.Sandbox

  @type metrics :: %{duration_ms: integer(), memory_bytes: integer()}

  @type error ::
          {:parse_error, String.t()}
          | {:validation_error, String.t()}
          | {:execution_error, String.t()}
          | {:timeout, non_neg_integer()}
          | {:memory_exceeded, non_neg_integer()}

  @spec run(String.t() | map(), keyword()) :: {:ok, any(), metrics()} | {:error, error()}
  def run(program, opts \\ []) do
    # Current PtcRunner.run/2 logic
  end

  @spec run!(String.t() | map(), keyword()) :: any()
  def run!(program, opts \\ []) do
    # Current PtcRunner.run!/2 logic
  end

  @spec format_error(error()) :: String.t()
  def format_error(error) do
    # Current PtcRunner.format_error/1 logic
  end
end
```

#### 1.2 Move existing modules

| Current Location | New Location |
|-----------------|--------------|
| `lib/ptc_runner/parser.ex` | `lib/ptc_runner/json/parser.ex` |
| `lib/ptc_runner/validator.ex` | `lib/ptc_runner/json/validator.ex` |
| `lib/ptc_runner/interpreter.ex` | `lib/ptc_runner/json/interpreter.ex` |
| `lib/ptc_runner/operations.ex` | `lib/ptc_runner/json/operations.ex` |

#### 1.3 Update module names

```elixir
# Before
defmodule PtcRunner.Parser do

# After
defmodule PtcRunner.Json.Parser do
```

#### 1.4 Deprecate `PtcRunner.run/2`

```elixir
# lib/ptc_runner.ex
defmodule PtcRunner do
  @moduledoc """
  BEAM-native Programmatic Tool Calling runner.

  ## Languages

  PtcRunner supports multiple DSL languages:

  - `PtcRunner.Json` - JSON-based DSL (stable)
  - `PtcRunner.Lisp` - Clojure-like DSL (stable)

  ## Migration

  The top-level `run/2` function is deprecated. Use language-specific modules:

      # Before (deprecated)
      PtcRunner.run(json_program, opts)

      # After
      PtcRunner.Json.run(json_program, opts)
  """

  @deprecated "Use PtcRunner.Json.run/2 instead"
  defdelegate run(program, opts \\ []), to: PtcRunner.Json

  @deprecated "Use PtcRunner.Json.run!/2 instead"
  defdelegate run!(program, opts \\ []), to: PtcRunner.Json

  @deprecated "Use PtcRunner.Json.format_error/1 instead"
  defdelegate format_error(error), to: PtcRunner.Json
end
```

#### 1.5 Files to modify

| File | Change |
|------|--------|
| `lib/ptc_runner.ex` | Replace implementation with delegation + deprecation |
| `lib/ptc_runner/parser.ex` | Rename module to `PtcRunner.Json.Parser` |
| `lib/ptc_runner/validator.ex` | Rename module to `PtcRunner.Json.Validator` |
| `lib/ptc_runner/interpreter.ex` | Rename module to `PtcRunner.Json.Interpreter` |
| `lib/ptc_runner/operations.ex` | Rename module to `PtcRunner.Json.Operations` |
| All test files | Update module references |

---

### Phase 2: Update Tests

#### 2.1 Test file changes

**Move to `json/` namespace:**

| Current | New |
|---------|-----|
| `test/ptc_runner_test.exs` | `test/ptc_runner/json_test.exs` |
| `test/ptc_runner/parser_test.exs` | `test/ptc_runner/json/parser_test.exs` |
| `test/ptc_runner/validator_test.exs` | `test/ptc_runner/json/validator_test.exs` |
| `test/ptc_runner/interpreter_test.exs` | `test/ptc_runner/json/interpreter_test.exs` |
| `test/ptc_runner/e2e_test.exs` | `test/ptc_runner/json/e2e_test.exs` |
| `test/ptc_runner/operations_introspection_test.exs` | `test/ptc_runner/json/operations_introspection_test.exs` |
| `test/ptc_runner/operations/aggregation_test.exs` | `test/ptc_runner/json/operations/aggregation_test.exs` |
| `test/ptc_runner/operations/collection_test.exs` | `test/ptc_runner/json/operations/collection_test.exs` |
| `test/ptc_runner/operations/comparison_test.exs` | `test/ptc_runner/json/operations/comparison_test.exs` |
| `test/ptc_runner/operations/control_flow_test.exs` | `test/ptc_runner/json/operations/control_flow_test.exs` |
| `test/ptc_runner/operations/data_source_test.exs` | `test/ptc_runner/json/operations/data_source_test.exs` |
| `test/ptc_runner/operations/error_handling_test.exs` | `test/ptc_runner/json/operations/error_handling_test.exs` |
| `test/ptc_runner/operations/transformation_test.exs` | `test/ptc_runner/json/operations/transformation_test.exs` |
| `test/ptc_runner/operations/tool_call_test.exs` | `test/ptc_runner/json/operations/tool_call_test.exs` |

**Keep in place (shared infrastructure):**

| File | Reason |
|------|--------|
| `test/ptc_runner/sandbox_test.exs` | Tests shared sandbox module |
| `test/ptc_runner/context_test.exs` | Tests shared context module |
| `test/ptc_runner/schema_test.exs` | Tests shared schema module |
| `test/test_helper.exs` | Test configuration |

#### 2.2 Update test module names and aliases

```elixir
# Before
defmodule PtcRunner.ParserTest do
  alias PtcRunner.Parser

# After
defmodule PtcRunner.Json.ParserTest do
  alias PtcRunner.Json.Parser
```

---

### Phase 3: Update Documentation

#### 3.1 Split architecture.md

Extract JSON-specific content into a new file, keeping shared architecture separate:

**New file structure:**
```
docs/
├── architecture.md              # Shared: sandbox, context, tools, resource limits
├── ptc-json-specification.md    # JSON DSL operations, semantics, examples
└── ptc-lisp-specification.md    # Already exists
```

**Move from architecture.md to ptc-json-specification.md:**
- DSL Specification section (operations tables)
- Semantic Specifications section
- Example Programs section

**Keep in architecture.md:**
- Overview and design principles
- Module structure (update for new layout)
- Public API overview (both languages)
- Tool registration
- Resource limits
- Sandbox implementation
- Error messages

#### 3.2 README.md changes

- Update quick example to use `PtcRunner.Json.run/2`
- Add section about language selection
- Update all code examples

#### 3.3 PTC-Lisp docs updates

- `docs/ptc-lisp-overview.md`: Update API examples to `PtcRunner.Lisp.run/2`
- `docs/ptc-lisp-llm-guide.md`: Update Elixir integration examples
- Remove hardcoded timeout values from docs (use "configurable" instead)

#### 3.4 CLAUDE.md changes

- Update project structure section

---

### Phase 4: Prepare Lisp Module Skeleton

Create empty module structure for future Lisp implementation.

```elixir
# lib/ptc_runner/lisp.ex
defmodule PtcRunner.Lisp do
  @moduledoc """
  Execute PTC programs written in PTC-Lisp (Clojure-like syntax).

  **Status:** Not yet implemented. See `docs/ptc-lisp-overview.md`.
  """

  @doc """
  Runs a PTC-Lisp program.

  ## Options

  Same as `PtcRunner.Json.run/2`:
  - `:context` - Map of pre-bound variables
  - `:tools` - Tool registry
  - `:timeout` - Timeout in milliseconds
  - `:max_heap` - Max heap size in words
  """
  @spec run(String.t(), keyword()) :: {:ok, any(), map()} | {:error, term()}
  def run(_source, _opts \\ []) do
    {:error, {:not_implemented, "PTC-Lisp support is not yet implemented"}}
  end

  @spec run!(String.t(), keyword()) :: any()
  def run!(source, opts \\ []) do
    case run(source, opts) do
      {:ok, result, _metrics} -> result
      {:error, reason} -> raise "PtcRunner.Lisp error: #{inspect(reason)}"
    end
  end
end
```

---

## File Change Summary

### New Files

| Path | Description |
|------|-------------|
| `lib/ptc_runner/json.ex` | JSON DSL public API |
| `lib/ptc_runner/lisp.ex` | Lisp DSL placeholder |
| `docs/ptc-json-specification.md` | JSON DSL operations, semantics, examples (extracted from architecture.md) |
| `test/ptc_runner/json_test.exs` | Main JSON tests |

### Renamed/Moved Files

**Library files:**

| From | To |
|------|-----|
| `lib/ptc_runner/parser.ex` | `lib/ptc_runner/json/parser.ex` |
| `lib/ptc_runner/validator.ex` | `lib/ptc_runner/json/validator.ex` |
| `lib/ptc_runner/interpreter.ex` | `lib/ptc_runner/json/interpreter.ex` |
| `lib/ptc_runner/operations.ex` | `lib/ptc_runner/json/operations.ex` |

**Test files:**

| From | To |
|------|-----|
| `test/ptc_runner_test.exs` | `test/ptc_runner/json_test.exs` |
| `test/ptc_runner/parser_test.exs` | `test/ptc_runner/json/parser_test.exs` |
| `test/ptc_runner/validator_test.exs` | `test/ptc_runner/json/validator_test.exs` |
| `test/ptc_runner/interpreter_test.exs` | `test/ptc_runner/json/interpreter_test.exs` |
| `test/ptc_runner/e2e_test.exs` | `test/ptc_runner/json/e2e_test.exs` |
| `test/ptc_runner/operations_introspection_test.exs` | `test/ptc_runner/json/operations_introspection_test.exs` |
| `test/ptc_runner/operations/` (all files) | `test/ptc_runner/json/operations/` |

### Modified Files

| Path | Change |
|------|--------|
| `lib/ptc_runner.ex` | Replace with deprecation delegates |
| `lib/ptc_runner/sandbox.ex` | No change (shared) |
| `lib/ptc_runner/context.ex` | No change (shared) |
| `lib/ptc_runner/schema.ex` | No change (shared) |
| `README.md` | Update examples to `PtcRunner.Json` |
| `CLAUDE.md` | Update project structure |
| `docs/architecture.md` | Extract JSON-specific content, update module structure and API |
| `docs/ptc-lisp-overview.md` | Update API examples, remove timeout values |
| `docs/ptc-lisp-llm-guide.md` | Update integration examples |
| `docs/ptc-lisp-specification.md` | Remove hardcoded timeout values |
| `docs/ptc-lisp-integration-spec.md` | Update API examples |
| `demo/README.md` | Update to use `PtcRunner.Json` |

---

## Verification Checklist

After refactoring, verify:

- [ ] `mix compile --warnings-as-errors` passes
- [ ] `mix test` passes (all existing tests)
- [ ] `mix format --check-formatted` passes
- [ ] Deprecation warnings appear for old API usage
- [ ] `PtcRunner.Json.run/2` works identically to old `PtcRunner.run/2`
- [ ] `PtcRunner.Lisp.run/2` returns `{:error, {:not_implemented, ...}}`
- [ ] Documentation builds without errors (`mix docs`)

---

## Future Work

After this refactoring is complete:

1. Implement `PtcRunner.Lisp.Parser` using NimbleParsec
2. Implement `PtcRunner.Lisp.Analyzer` for AST transformation
3. Implement `PtcRunner.Lisp.Interpreter` with closures
4. Add `memory/` namespace support to Context
5. Add comprehensive Lisp tests
