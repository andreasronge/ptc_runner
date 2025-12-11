defmodule PtcRunner.Json.MemoryContractTest do
  use ExUnit.Case, async: true

  describe "memory contract" do
    test "scalar result does not update memory" do
      program = ~s({"program": {"op": "literal", "value": 42}})
      initial_memory = %{"existing_key" => "preserved"}

      {:ok, result, memory_delta, new_memory} =
        PtcRunner.Json.run(program, memory: initial_memory)

      assert result == 42
      assert memory_delta == %{}
      assert new_memory == initial_memory
    end

    test "map result merges entire map to memory (JSON doesn't distinguish :result)" do
      program = ~s({"program": {"op": "literal", "value": {"foo": "bar", "baz": "qux"}}})
      initial_memory = %{}

      {:ok, result, memory_delta, new_memory} =
        PtcRunner.Json.run(program, memory: initial_memory)

      # JSON keys are strings, so the entire map is returned and merged into memory
      assert result == %{"foo" => "bar", "baz" => "qux"}
      assert memory_delta == %{"foo" => "bar", "baz" => "qux"}
      assert new_memory == %{"foo" => "bar", "baz" => "qux"}
    end

    test "empty map result merges nothing but verifies contract" do
      program = ~s({"program": {"op": "literal", "value": {}}})
      initial_memory = %{"existing" => "value"}

      {:ok, result, memory_delta, new_memory} =
        PtcRunner.Json.run(program, memory: initial_memory)

      assert result == %{}
      assert memory_delta == %{}
      assert new_memory == %{"existing" => "value"}
    end

    test "initial memory is preserved with scalar result" do
      program = ~s({"program": {"op": "literal", "value": 42}})
      initial_memory = %{"existing_key" => "value1", "another_key" => "value2"}

      {:ok, result, memory_delta, new_memory} =
        PtcRunner.Json.run(program, memory: initial_memory)

      assert result == 42
      assert memory_delta == %{}
      assert new_memory == initial_memory
      assert new_memory == %{"existing_key" => "value1", "another_key" => "value2"}
    end

    test "memory merge overwrites initial memory keys" do
      program = ~s({"program": {"op": "literal", "value": {"foo": 2, "new_key": "added"}}})
      initial_memory = %{"foo" => 1, "baz" => 3}

      {:ok, result, memory_delta, new_memory} =
        PtcRunner.Json.run(program, memory: initial_memory)

      assert result == %{"foo" => 2, "new_key" => "added"}
      assert memory_delta == %{"foo" => 2, "new_key" => "added"}
      assert new_memory == %{"foo" => 2, "baz" => 3, "new_key" => "added"}
    end
  end
end
