defmodule PtcRunner.Lisp.MemoryContractTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Step

  @moduledoc """
  Tests for V2 simplified memory contract.

  V2 model: No implicit map-to-memory merge. Storage is explicit via `def`.
  All values pass through unchanged. Memory only changes via user_ns bindings.
  """

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

  describe "map results (no implicit merge)" do
    test "map returns as-is, memory unchanged" do
      source = "{:cached-count 3}"
      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} = Lisp.run(source)

      assert result == %{:"cached-count" => 3}
      assert delta == %{}
      assert new_memory == %{}
    end

    test "map does not affect initial memory" do
      initial_memory = %{x: 10}
      source = "{:y 20}"

      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} =
        Lisp.run(source, memory: initial_memory)

      assert result == %{y: 20}
      assert delta == %{}
      assert new_memory == %{x: 10}
    end

    test "map with :return key passes through unchanged (no special handling)" do
      source = "{:return 42, :stored 100}"
      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} = Lisp.run(source)

      # :return is just a regular key now, no special extraction
      assert result == %{return: 42, stored: 100}
      assert delta == %{}
      assert new_memory == %{}
    end

    test "empty map returns empty, memory unchanged" do
      initial_memory = %{x: 10}
      source = "{}"

      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} =
        Lisp.run(source, memory: initial_memory)

      assert result == %{}
      assert delta == %{}
      assert new_memory == %{x: 10}
    end
  end

  describe "explicit storage via def" do
    test "def stores value in user_ns, accessible in same expression" do
      source = "(do (def x 42) x)"
      {:ok, %{return: result}} = Lisp.run(source)

      assert result == 42
    end

    test "def with complex value" do
      source = ~S|(do (def results {:count 5, :items [1 2 3]}) (:count results))|
      {:ok, %{return: result}} = Lisp.run(source)

      assert result == 5
    end

    test "multiple defs in sequence" do
      source = "(do (def a 1) (def b 2) (+ a b))"
      {:ok, %{return: result}} = Lisp.run(source)

      assert result == 3
    end
  end
end
