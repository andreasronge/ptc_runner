# Testing Guidelines

## Quick Reference

```bash
mix test                       # Run all tests
mix test --failed              # Re-run failed tests
mix test test/path_test.exs    # Run specific test file
mix test test/path_test.exs:42 # Run test at specific line
mix test --trace               # Verbose output
```

## Test Organization

```
test/
├── ptc_runner/
│   ├── json/               # JSON DSL tests
│   │   ├── parser_test.exs
│   │   ├── interpreter_test.exs
│   │   └── operations/     # Operation-specific tests
│   └── lisp/               # Lisp DSL tests
│       ├── parser_test.exs
│       ├── eval_test.exs
│       └── formatter_test.exs
├── support/                # Test helpers and generators
└── test_helper.exs         # Test configuration
```

## Core Rules

1. **Test behavior, not implementation** - Tests should survive refactoring
2. **Strong assertions** - Assert specific values, not just shapes
3. **No `Process.sleep`** - Use monitors or async helpers for timing
4. **One test per behavior** - Avoid testing the same thing multiple ways

## Test Quality

### Strong Assertions

```elixir
# GOOD - Specific assertions
assert result == {:ok, %{count: 5, items: ["a", "b"]}}
assert error.message == "Invalid operation: unknown_op"

# BAD - Weak assertions
assert {:ok, _} = result
assert is_map(result)
assert match?({:error, _}, error)
```

### Test Structure

```elixir
describe "parse/1" do
  test "parses valid JSON DSL" do
    input = ~s({"op": "filter", "field": "name"})

    assert {:ok, ast} = Parser.parse(input)
    assert ast.operation == :filter
    assert ast.field == "name"
  end

  test "returns error for invalid JSON" do
    assert {:error, %ParseError{}} = Parser.parse("not json")
  end

  test "returns error for unknown operation" do
    input = ~s({"op": "unknown"})

    assert {:error, %ParseError{message: message}} = Parser.parse(input)
    assert message =~ "unknown operation"
  end
end
```

### Avoid Duplication

- Extract common setup to `setup` blocks
- Use helper functions for repeated assertions
- Don't test the same behavior in multiple places

## Testing Async/Concurrent Code

### Use Process Monitors

```elixir
test "sandbox terminates on timeout" do
  {:ok, pid} = Sandbox.start(timeout: 100)
  ref = Process.monitor(pid)

  Sandbox.run(pid, long_running_program())

  assert_receive {:DOWN, ^ref, :process, ^pid, :timeout}, 500
end
```

### Async Assertion Helper

For eventual consistency, create a helper:

```elixir
defp eventually(fun, timeout \\ 2000) do
  deadline = System.monotonic_time(:millisecond) + timeout
  do_eventually(fun, deadline)
end

defp do_eventually(fun, deadline) do
  try do
    fun.()
  rescue
    ExUnit.AssertionError ->
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        do_eventually(fun, deadline)
      else
        fun.()  # Let it fail with original error
      end
  end
end

# Usage
test "registry updates eventually" do
  send(pid, :update)

  eventually(fn ->
    assert Registry.lookup(MyRegistry, key) == [{pid, value}]
  end)
end
```

## Testing Parsers

### Edge Cases

Always test:
- Empty input
- Malformed input (invalid JSON, missing fields)
- Boundary values (empty arrays, deeply nested structures)
- Unicode and special characters
- Very large inputs

## Testing the Interpreter

### Sandbox Safety Tests

```elixir
describe "sandbox safety" do
  test "prevents infinite loops via timeout" do
    program = %{op: "loop", body: %{op: "noop"}}

    assert {:error, :timeout} = Sandbox.run(program, timeout: 100)
  end

  test "limits memory usage" do
    program = %{op: "allocate", size: 1_000_000_000}

    assert {:error, :memory_limit} = Sandbox.run(program, max_memory: 1_000_000)
  end

  test "only allows whitelisted operations" do
    program = %{op: "system_call", cmd: "rm -rf /"}

    assert {:error, %{message: "operation not allowed"}} = Sandbox.run(program)
  end
end
```

### Tool Call Testing

```elixir
describe "tool calls" do
  setup do
    # Register a test tool
    Tools.register(:echo, fn args -> {:ok, args} end)
    :ok
  end

  test "calls registered tool with arguments" do
    program = %{op: "call", tool: "echo", args: %{message: "hello"}}

    assert {:ok, %{message: "hello"}} = Interpreter.run(program)
  end

  test "returns error for unregistered tool" do
    program = %{op: "call", tool: "unknown", args: %{}}

    assert {:error, %{message: "tool not found: unknown"}} = Interpreter.run(program)
  end
end
```

## Verify Tests Actually Test

After writing a test:
1. Run it - should pass
2. Break the implementation - test MUST fail
3. If test still passes, rewrite it

## Test Tags

```elixir
# Slow tests (skip by default)
@tag :slow
test "processes large dataset" do
  # ...
end

# Run with: mix test --include slow

# Integration tests
@tag :integration
test "full pipeline" do
  # ...
end
```

## PTC-Lisp Specification Tests

The spec (`docs/ptc-lisp-specification.md`) contains executable examples (lines with `; =>`) validated against the implementation:

```bash
mix ptc.validate_spec              # Validate all spec examples
mix ptc.validate_spec --clojure    # Also compare with Babashka
```

Section checksums detect unintended spec changes. After intentionally modifying the spec:

```bash
mix ptc.update_spec_checksums
git add test/spec_cases/checksums.exs
```

## Property-Based Testing

Use StreamData for testing invariants across many random inputs. Good candidates:
- **Roundtrip properties**: parse → format → parse = original
- **Algebraic laws**: `x + 0 = x`, `reverse(reverse(xs)) = xs`
- **Safety invariants**: "no valid input causes a crash"

```elixir
use ExUnitProperties

property "reverse is involutive" do
  check all items <- list_of(integer()) do
    assert Enum.reverse(Enum.reverse(items)) == items
  end
end
```

Run property tests: `mix test test/support/lisp_generators_test.exs`

See `test/support/lisp_generators.ex` for existing generators.

## Quiet Test Output

Tests must run without noisy log output. Expected errors (like sandbox process crashes during property tests) should not pollute the test output.

The `test_helper.exs` sets the OTP logger level to `:critical` to suppress process crash reports:

```elixir
Logger.configure(level: :warning)
:logger.set_primary_config(:level, :critical)
```

This suppresses error-level logs (including spawned process exceptions) while still allowing critical/emergency logs through. This is preferred over `:none` because truly critical issues would still be logged.

For tests that need to verify log output, use `@tag :capture_log`:

```elixir
@tag :capture_log
test "logs warning for deprecated usage" do
  assert ExUnit.CaptureLog.capture_log(fn ->
    MyModule.deprecated_function()
  end) =~ "deprecated"
end
```

## Checklist

- [ ] Tests are in the correct location
- [ ] Each test has a clear, descriptive name
- [ ] Assertions are specific (not just shape matching)
- [ ] No `Process.sleep` for timing (use monitors/helpers)
- [ ] Edge cases covered (empty, invalid, boundary)
- [ ] Test actually fails when implementation is broken
- [ ] No noisy log output (use `@tag :capture_log` for expected errors)
