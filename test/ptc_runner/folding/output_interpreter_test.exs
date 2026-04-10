defmodule PtcRunner.Folding.OutputInterpreterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.OutputInterpreter

  @base_ctx %{
    "products" => [%{"price" => 100}, %{"price" => 200}, %{"price" => 300}],
    "employees" => [%{"name" => "A"}, %{"name" => "B"}]
  }

  describe "interpret/3" do
    test "list of maps replaces the detected data source" do
      output = [%{"price" => 500}, %{"price" => 600}]
      result = OutputInterpreter.interpret("(map ... data/products)", output, @base_ctx)

      assert result["products"] == output
      # Other sources unchanged
      assert result["employees"] == @base_ctx["employees"]
    end

    test "non-list output returns base context unchanged" do
      assert OutputInterpreter.interpret("anything", 42, @base_ctx) == @base_ctx
      assert OutputInterpreter.interpret("anything", "hello", @base_ctx) == @base_ctx
      assert OutputInterpreter.interpret("anything", nil, @base_ctx) == @base_ctx
      assert OutputInterpreter.interpret("anything", true, @base_ctx) == @base_ctx
    end

    test "empty list returns base context unchanged" do
      assert OutputInterpreter.interpret("data/products", [], @base_ctx) == @base_ctx
    end

    test "list without maps returns base context unchanged" do
      assert OutputInterpreter.interpret("data/products", [1, 2, 3], @base_ctx) == @base_ctx
    end

    test "detects employees data source" do
      output = [%{"name" => "Z"}]
      result = OutputInterpreter.interpret("(filter ... data/employees)", output, @base_ctx)
      assert result["employees"] == output
    end

    test "unknown source returns base context unchanged" do
      output = [%{"x" => 1}]
      assert OutputInterpreter.interpret("some random thing", output, @base_ctx) == @base_ctx
    end

    test "nil source returns base context unchanged" do
      output = [%{"x" => 1}]
      assert OutputInterpreter.interpret(nil, output, @base_ctx) == @base_ctx
    end
  end

  describe "detect_source/1" do
    test "detects data/products" do
      assert {:ok, "products"} = OutputInterpreter.detect_source("(count data/products)")
    end

    test "detects data/employees" do
      assert {:ok, "employees"} = OutputInterpreter.detect_source("(map fn data/employees)")
    end

    test "detects data/orders" do
      assert {:ok, "orders"} = OutputInterpreter.detect_source("(filter fn data/orders)")
    end

    test "returns unknown for no data source" do
      assert :unknown = OutputInterpreter.detect_source("(+ 1 2)")
    end

    test "returns unknown for nil" do
      assert :unknown = OutputInterpreter.detect_source(nil)
    end
  end
end
