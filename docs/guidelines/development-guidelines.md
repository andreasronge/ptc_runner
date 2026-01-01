# Development Guidelines

This is an Elixir library for Programmatic Tool Calling (PTC).

See **[Documentation](../README.md)** for system design and API reference. See **[PTC-JSON Specification](../reference/ptc-json-specification.md)** and **[PTC-Lisp Specification](../ptc-lisp-specification.md)** for DSL details.

## Project Guidelines

- Run `mix format --check-formatted && mix compile --warnings-as-errors && mix test` before committing
- Use `Req` library for HTTP requests if needed, **avoid** `:httpoison`, `:tesla`, and `:httpc`

## Elixir Guidelines

- Elixir lists **do not support index-based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index-based list access:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc. you *must* bind the result of the expression to a variable if you want to use it:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        result = compute()
      end

      # VALID: we rebind the result of the `if` to a new variable
      result =
        if connected?(socket) do
          compute()
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry` require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix Guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Data Type Conventions

**Purpose**: Ensure consistency in internal data representation across the codebase. These conventions prevent bugs from type mismatches and unit confusion.

### Duration Storage

**Rule**: Store all durations as **integer milliseconds** in internal data structures. Convert to human-readable formats only at display time.

**Why milliseconds?**
- **Precision**: Captures sub-second durations accurately
- **No floating point errors**: Integers are exact
- **Industry standard**: Most systems use milliseconds internally

```elixir
# GOOD - Use integer milliseconds
%{duration_ms: 2500}  # 2.5 seconds

# BAD - Don't use seconds or floats
%{duration_seconds: 2}  # Too coarse
%{duration: 2.5}        # Floating point errors
```

### Timestamp Storage

**Rule**: Always use `DateTime` with UTC timezone. Never use naive datetime.

```elixir
# GOOD
DateTime.utc_now()

# BAD
NaiveDateTime.utc_now()  # Loses timezone context
```

## Library Design Principles

### DRY (Don't Repeat Yourself)

- Extract repeated logic into helper functions
- If you copy-paste code, refactor into a reusable function
- Exception: Duplication is better than the wrong abstraction

For test code, see [Testing Guidelines - Avoid Duplication](testing-guidelines.md#avoid-duplication).

### Public API

- Keep the public API minimal and well-documented
- Use `@moduledoc` and `@doc` for all public functions
- Consider using `@spec` for type documentation
- Hide implementation details in private functions

### Error Handling

- Use tagged tuples for expected errors: `{:ok, result}` or `{:error, reason}`
- Use exceptions for programmer errors (bugs)
- Provide meaningful error messages with context

### Process Safety

Since this library may run LLM-generated code:
- Only allow a fixed set of safe operations in the DSL
- Implement strict timeouts for program execution
- Consider memory limits for sandbox processes
- Log all tool calls for debugging and auditing

### Testing

- Test the public API surface thoroughly
- Use property-based testing for parsers/interpreters where appropriate
- Include edge cases for malformed input

## Code Organization

See [Documentation - Module Structure](../README.md#module-structure) for the current layout.

```
lib/
├── ptc_runner.ex           # Main public API: run/2, run!/2
├── ptc_runner/
│   ├── parser.ex           # JSON parsing
│   ├── validator.ex        # Schema validation
│   ├── interpreter.ex      # AST evaluation
│   ├── operations.ex       # Built-in operations
│   ├── sandbox.ex          # Process isolation + resource limits
│   ├── context.ex          # Variable bindings and tool results
│   └── tools.ex            # Tool registry
```
