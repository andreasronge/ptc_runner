defmodule PtcRunner.Lisp.AnalyzeMemoryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Analyze

  describe "memory/put" do
    test "analyzes memory/put with keyword and value" do
      raw = {:list, [{:ns_symbol, :memory, :put}, {:keyword, :count}, 42]}
      assert {:ok, {:memory_put, :count, 42}} = Analyze.analyze(raw)
    end

    test "analyzes memory/put with expression value" do
      raw = {:list, [{:ns_symbol, :memory, :put}, {:keyword, :result}, {:symbol, :x}]}
      assert {:ok, {:memory_put, :result, {:var, :x}}} = Analyze.analyze(raw)
    end

    test "memory/put requires keyword as key" do
      raw = {:list, [{:ns_symbol, :memory, :put}, {:string, "not-a-keyword"}, 42]}

      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "memory operations require a keyword as key"
    end

    test "memory/put requires exactly 2 arguments" do
      raw = {:list, [{:ns_symbol, :memory, :put}, {:keyword, :key}]}

      assert {:error, {:invalid_arity, :"memory/put", msg}} = Analyze.analyze(raw)
      assert msg =~ "expected (memory/put :key value)"
    end
  end

  describe "memory/get" do
    test "analyzes memory/get with keyword" do
      raw = {:list, [{:ns_symbol, :memory, :get}, {:keyword, :count}]}
      assert {:ok, {:memory_get, :count}} = Analyze.analyze(raw)
    end

    test "memory/get requires keyword as key" do
      raw = {:list, [{:ns_symbol, :memory, :get}, {:string, "not-a-keyword"}]}

      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "memory operations require a keyword as key"
    end

    test "memory/get requires exactly 1 argument" do
      raw = {:list, [{:ns_symbol, :memory, :get}, {:keyword, :key}, 42]}

      assert {:error, {:invalid_arity, :"memory/get", msg}} = Analyze.analyze(raw)
      assert msg =~ "expected (memory/get :key)"
    end
  end
end
