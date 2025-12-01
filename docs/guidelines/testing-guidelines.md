# Testing Guidelines

## Quick Reference

```bash
mix test                    # Run all tests
mix test --failed           # Re-run failed tests
mix test test/path_test.exs # Run specific test file
mix test --trace            # Verbose output
```

## Test Organization

```
test/
├── ptc_runner_test.exs     # Main module tests
├── ptc_runner/
│   ├── parser_test.exs     # Parser tests
│   ├── interpreter_test.exs # Interpreter tests
│   └── tools_test.exs      # Tool integration tests
├── support/                # Test helpers
│   └── fixtures/           # Test data
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

### Property-Based Testing

Consider using StreamData for parser testing:

```elixir
# In mix.exs deps
{:stream_data, "~> 1.0", only: [:test]}

# In test
use ExUnitProperties

property "round-trips valid AST" do
  check all ast <- valid_ast_generator() do
    json = AST.to_json(ast)
    assert {:ok, ^ast} = Parser.parse(json)
  end
end
```

### Edge Cases for Parsers

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

## Checklist

- [ ] Tests are in the correct location
- [ ] Each test has a clear, descriptive name
- [ ] Assertions are specific (not just shape matching)
- [ ] No `Process.sleep` for timing (use monitors/helpers)
- [ ] Edge cases covered (empty, invalid, boundary)
- [ ] Test actually fails when implementation is broken
