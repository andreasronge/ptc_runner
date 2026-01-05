defmodule PtcRunner.Lisp.AnalyzeClojureCompatTest do
  @moduledoc """
  Tests for Clojure namespace normalization.

  PTC-Lisp normalizes common Clojure-style namespaced symbols to built-ins,
  making LLM-generated code more resilient.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Analyze

  describe "clojure.string namespace normalization" do
    test "clojure.string/join normalizes to join" do
      raw = {:ns_symbol, :"clojure.string", :join}
      assert {:ok, {:var, :join}} = Analyze.analyze(raw)
    end

    test "clojure.string/split normalizes to split" do
      raw = {:ns_symbol, :"clojure.string", :split}
      assert {:ok, {:var, :split}} = Analyze.analyze(raw)
    end

    test "clojure.string/includes? normalizes to includes?" do
      raw = {:ns_symbol, :"clojure.string", :includes?}
      assert {:ok, {:var, :includes?}} = Analyze.analyze(raw)
    end

    test "clojure.string/trim normalizes to trim" do
      raw = {:ns_symbol, :"clojure.string", :trim}
      assert {:ok, {:var, :trim}} = Analyze.analyze(raw)
    end
  end

  describe "str shorthand namespace" do
    test "str/join normalizes to join" do
      raw = {:ns_symbol, :str, :join}
      assert {:ok, {:var, :join}} = Analyze.analyze(raw)
    end

    test "str/split normalizes to split" do
      raw = {:ns_symbol, :str, :split}
      assert {:ok, {:var, :split}} = Analyze.analyze(raw)
    end
  end

  describe "string shorthand namespace" do
    test "string/replace normalizes to replace" do
      raw = {:ns_symbol, :string, :replace}
      assert {:ok, {:var, :replace}} = Analyze.analyze(raw)
    end
  end

  describe "clojure.core namespace normalization" do
    test "clojure.core/map normalizes to map" do
      raw = {:ns_symbol, :"clojure.core", :map}
      assert {:ok, {:var, :map}} = Analyze.analyze(raw)
    end

    test "clojure.core/filter normalizes to filter" do
      raw = {:ns_symbol, :"clojure.core", :filter}
      assert {:ok, {:var, :filter}} = Analyze.analyze(raw)
    end

    test "clojure.core/reduce normalizes to reduce" do
      raw = {:ns_symbol, :"clojure.core", :reduce}
      assert {:ok, {:var, :reduce}} = Analyze.analyze(raw)
    end
  end

  describe "core shorthand namespace" do
    test "core/map normalizes to map" do
      raw = {:ns_symbol, :core, :map}
      assert {:ok, {:var, :map}} = Analyze.analyze(raw)
    end

    test "core/first normalizes to first" do
      raw = {:ns_symbol, :core, :first}
      assert {:ok, {:var, :first}} = Analyze.analyze(raw)
    end
  end

  describe "clojure.set namespace normalization" do
    test "clojure.set/set normalizes to set" do
      raw = {:ns_symbol, :"clojure.set", :set}
      assert {:ok, {:var, :set}} = Analyze.analyze(raw)
    end
  end

  describe "set shorthand namespace" do
    test "set/contains? normalizes to contains?" do
      raw = {:ns_symbol, :set, :contains?}
      assert {:ok, {:var, :contains?}} = Analyze.analyze(raw)
    end
  end

  describe "call position normalization" do
    test "(clojure.string/join) works in call position" do
      raw = {:list, [{:ns_symbol, :"clojure.string", :join}, {:string, ","}, {:vector, []}]}
      assert {:ok, {:call, {:var, :join}, [{:string, ","}, {:vector, []}]}} = Analyze.analyze(raw)
    end

    test "(str/split) works in call position" do
      raw = {:list, [{:ns_symbol, :str, :split}, {:symbol, :s}, {:string, ","}]}
      assert {:ok, {:call, {:var, :split}, [{:var, :s}, {:string, ","}]}} = Analyze.analyze(raw)
    end

    test "(core/map) works in call position" do
      raw = {:list, [{:ns_symbol, :core, :map}, {:symbol, :inc}, {:vector, [1, 2, 3]}]}

      assert {:ok, {:call, {:var, :map}, [{:var, :inc}, {:vector, [1, 2, 3]}]}} =
               Analyze.analyze(raw)
    end
  end

  describe "unknown function in known namespace" do
    test "clojure.string/capitalize gives helpful error with string functions" do
      raw = {:ns_symbol, :"clojure.string", :capitalize}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "capitalize is not available"
      assert msg =~ "String functions:"
      assert msg =~ "join"
      assert msg =~ "split"
      assert msg =~ "trim"
    end

    test "str/blank? gives helpful error" do
      raw = {:ns_symbol, :str, :blank?}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "blank? is not available"
      assert msg =~ "String functions:"
    end

    test "clojure.core/nonexistent gives helpful error with core functions" do
      raw = {:ns_symbol, :"clojure.core", :nonexistent}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "nonexistent is not available"
      assert msg =~ "Core functions:"
      assert msg =~ "map"
      assert msg =~ "filter"
    end

    test "clojure.set/union gives helpful error with set functions" do
      raw = {:ns_symbol, :"clojure.set", :union}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "union is not available"
      assert msg =~ "Set functions:"
      assert msg =~ "set"
      assert msg =~ "contains?"
    end
  end

  describe "unknown function in call position" do
    test "(clojure.string/capitalize s) gives helpful error" do
      raw = {:list, [{:ns_symbol, :"clojure.string", :capitalize}, {:symbol, :s}]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "capitalize is not available"
      assert msg =~ "String functions:"
    end
  end

  describe "unknown namespace still errors" do
    test "unknown namespace in symbol position" do
      raw = {:ns_symbol, :my_ns, :foo}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "unknown namespace"
      assert msg =~ "my_ns"
      assert msg =~ "ctx/"
    end

    test "unknown namespace in call position" do
      raw = {:list, [{:ns_symbol, :custom, :func}, {:symbol, :x}]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "unknown namespace"
      assert msg =~ "custom"
    end
  end

  describe "ctx namespace still works" do
    test "ctx/input still works as context access" do
      raw = {:ns_symbol, :ctx, :input}
      assert {:ok, {:ctx, :input}} = Analyze.analyze(raw)
    end

    test "ctx/tool-name in call position still works" do
      raw = {:list, [{:ns_symbol, :ctx, :search}, {:map, []}]}
      assert {:ok, {:ctx_call, :search, [{:map, []}]}} = Analyze.analyze(raw)
    end
  end

  describe "cross-category builtins are normalized (permissive for LLM robustness)" do
    test "str/map normalizes to map (core function via string namespace)" do
      raw = {:ns_symbol, :str, :map}
      assert {:ok, {:var, :map}} = Analyze.analyze(raw)
    end

    test "core/join normalizes to join (string function via core namespace)" do
      raw = {:ns_symbol, :core, :join}
      assert {:ok, {:var, :join}} = Analyze.analyze(raw)
    end

    test "set/filter normalizes to filter (core function via set namespace)" do
      raw = {:ns_symbol, :set, :filter}
      assert {:ok, {:var, :filter}} = Analyze.analyze(raw)
    end
  end
end
