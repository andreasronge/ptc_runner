defmodule PtcRunner.Lisp.MemoryContractTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Step

  describe "non-map results" do
    test "non-map result leaves memory unchanged" do
      assert {:ok, %{return: 3, memory_delta: %{}, memory: %{}}} = Lisp.run("(+ 1 2)")
    end

    test "non-map result with context" do
      assert {:ok, %{return: 10, memory_delta: %{}, memory: %{}}} =
               Lisp.run("ctx/x", context: %{x: 10})
    end

    test "non-map result with initial memory" do
      initial_mem = %{stored: 42}

      assert {:ok, %{return: 5, memory_delta: %{}, memory: ^initial_mem}} =
               Lisp.run("(+ 2 3)", memory: initial_mem)
    end

    test "scalar result does not update memory" do
      initial_memory = %{"existing_key" => "preserved"}

      {:ok, %Step{return: result, memory_delta: memory_delta, memory: new_memory}} =
        Lisp.run("42", memory: initial_memory)

      assert result == 42
      assert memory_delta == %{}
      assert new_memory == initial_memory
    end
  end

  describe "map without :return key" do
    test "map without :return merges into memory and returns map" do
      source = "{:cached-count 3}"
      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} = Lisp.run(source)

      assert result == %{:"cached-count" => 3}
      assert delta == %{:"cached-count" => 3}
      assert new_memory == %{:"cached-count" => 3}
    end

    test "map merge preserves existing memory keys" do
      initial_memory = %{x: 10}
      source = "{:y 20}"

      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} =
        Lisp.run(source, memory: initial_memory)

      assert result == %{y: 20}
      assert delta == %{y: 20}
      assert new_memory == %{x: 10, y: 20}
    end

    test "map update overwrites memory keys" do
      initial_memory = %{counter: 5}
      source = "{:counter 10}"

      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} =
        Lisp.run(source, memory: initial_memory)

      assert result == %{counter: 10}
      assert delta == %{counter: 10}
      assert new_memory == %{counter: 10}
    end

    test "empty map merges with memory but returns empty map" do
      initial_memory = %{x: 10}
      source = "{}"

      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} =
        Lisp.run(source, memory: initial_memory)

      assert result == %{}
      assert delta == %{}
      assert new_memory == %{x: 10}
    end

    test "map result without :result merges entire map to memory" do
      initial_memory = %{}

      {:ok, %Step{return: result, memory_delta: memory_delta, memory: new_memory}} =
        Lisp.run(~S|{:foo "bar" :baz "qux"}|, memory: initial_memory)

      assert result == %{foo: "bar", baz: "qux"}
      assert memory_delta == %{foo: "bar", baz: "qux"}
      assert new_memory == %{foo: "bar", baz: "qux"}
    end
  end

  describe "map with :return key" do
    test "map with :return extracts return value" do
      source = "{:return 42, :stored 100}"
      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} = Lisp.run(source)

      assert result == 42
      assert delta == %{stored: 100}
      assert new_memory == %{stored: 100}
    end

    test "map with :return key and multiple updates" do
      source = "{:return \"done\", :count 5, :status \"ok\"}"
      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} = Lisp.run(source)

      assert result == "done"
      assert delta == %{count: 5, status: "ok"}
      assert new_memory == %{count: 5, status: "ok"}
    end

    test "map with only :return key" do
      source = "{:return \"return-value\"}"
      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} = Lisp.run(source)

      assert result == "return-value"
      assert delta == %{}
      assert new_memory == %{}
    end

    test "map with :return merges with initial memory" do
      initial_memory = %{x: 10}
      source = "{:return \"ok\", :y 20}"

      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} =
        Lisp.run(source, memory: initial_memory)

      assert result == "ok"
      assert delta == %{y: 20}
      assert new_memory == %{x: 10, y: 20}
    end

    test "map with :return key set to nil returns nil" do
      source = "{:return nil, :stored 100}"
      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} = Lisp.run(source)

      assert result == nil
      assert delta == %{stored: 100}
      assert new_memory == %{stored: 100}
    end

    test "map result with :return returns return value and merges rest" do
      initial_memory = %{existing: "value"}

      {:ok, %Step{return: result, memory_delta: memory_delta, memory: new_memory}} =
        Lisp.run(~S|{:return 42 :computed "data"}|, memory: initial_memory)

      assert result == 42
      assert memory_delta == %{computed: "data"}
      assert new_memory == %{existing: "value", computed: "data"}
    end
  end

  describe "memory merge behavior" do
    test "memory merge overwrites existing keys" do
      initial_memory = %{foo: 1, baz: 3}

      {:ok, %Step{return: result, memory_delta: memory_delta, memory: new_memory}} =
        Lisp.run(~S|{:foo 2 :new_key "added"}|, memory: initial_memory)

      assert result == %{foo: 2, new_key: "added"}
      assert memory_delta == %{foo: 2, new_key: "added"}
      assert new_memory == %{foo: 2, baz: 3, new_key: "added"}
    end
  end
end
