defmodule PtcRunner.Lisp.MemoryContractTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Step

  describe "memory contract" do
    test "scalar result does not update memory" do
      initial_memory = %{"existing_key" => "preserved"}

      {:ok, %Step{return: result, memory_delta: memory_delta, memory: new_memory}} =
        PtcRunner.Lisp.run("42", memory: initial_memory)

      assert result == 42
      assert memory_delta == %{}
      assert new_memory == initial_memory
    end

    test "map result without :result merges entire map to memory" do
      initial_memory = %{}

      {:ok, %Step{return: result, memory_delta: memory_delta, memory: new_memory}} =
        PtcRunner.Lisp.run(~S|{:foo "bar" :baz "qux"}|, memory: initial_memory)

      assert result == %{foo: "bar", baz: "qux"}
      assert memory_delta == %{foo: "bar", baz: "qux"}
      assert new_memory == %{foo: "bar", baz: "qux"}
    end

    test "map result with :return returns return value and merges rest" do
      initial_memory = %{existing: "value"}

      {:ok, %Step{return: result, memory_delta: memory_delta, memory: new_memory}} =
        PtcRunner.Lisp.run(~S|{:return 42 :computed "data"}|, memory: initial_memory)

      assert result == 42
      assert memory_delta == %{computed: "data"}
      assert new_memory == %{existing: "value", computed: "data"}
    end

    test "memory merge overwrites existing keys" do
      initial_memory = %{foo: 1, baz: 3}

      {:ok, %Step{return: result, memory_delta: memory_delta, memory: new_memory}} =
        PtcRunner.Lisp.run(~S|{:foo 2 :new_key "added"}|, memory: initial_memory)

      assert result == %{foo: 2, new_key: "added"}
      assert memory_delta == %{foo: 2, new_key: "added"}
      assert new_memory == %{foo: 2, baz: 3, new_key: "added"}
    end
  end
end
