defmodule PtcRunner.Json.Operations.DataSourceTest do
  use ExUnit.Case

  # Basic literal operation
  test "literal returns the specified value" do
    program = ~s({"program": {"op": "literal", "value": 42}})
    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

    assert result == 42
  end

  # Load operation
  test "load retrieves variable from context" do
    program = ~s({"program": {"op": "load", "name": "data"}})

    {:ok, result, _memory_delta, _new_memory} =
      PtcRunner.Json.run(program, context: %{"data" => [1, 2, 3]})

    assert result == [1, 2, 3]
  end

  test "load returns nil for missing variable" do
    program = ~s({"program": {"op": "load", "name": "missing"}})
    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

    assert result == nil
  end
end
