defmodule PtcRunner.Lisp.AnalyzeClojureCompatTest do
  @moduledoc """
  Tests for Clojure namespace normalization.

  PTC-Lisp normalizes common Clojure-style namespaced symbols to built-ins,
  making LLM-generated code more resilient.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Analyze

  test "known Clojure namespaces normalize each supported symbol" do
    for {namespace, function} <- [
          {:"clojure.string", :join},
          {:"clojure.string", :split},
          {:"clojure.string", :includes?},
          {:"clojure.string", :blank?},
          {:"clojure.string", :trim},
          {:str, :join},
          {:str, :split},
          {:string, :replace},
          {:"clojure.core", :map},
          {:"clojure.core", :filter},
          {:"clojure.core", :reduce},
          {:"clojure.core", :str},
          {:"clojure.core", :subs},
          {:"clojure.core", :"re-find"},
          {:"clojure.core", :abs},
          {:core, :map},
          {:core, :first},
          {:"clojure.set", :set},
          {:"clojure.walk", :prewalk},
          {:"clojure.walk", :postwalk},
          {:"clojure.walk", :walk},
          {:set, :contains?},
          {:walk, :prewalk}
        ] do
      assert {:ok, {:var, ^function}} = Analyze.analyze({:ns_symbol, namespace, function})
    end
  end

  describe "Math namespace dispatch" do
    test "Math/sqrt preserves Java reference identity" do
      raw = {:ns_symbol, :Math, :sqrt}
      assert {:ok, {:java_ref, :math_sqrt}} = Analyze.analyze(raw)
    end

    test "Math/pow preserves Java reference identity" do
      raw = {:ns_symbol, :Math, :pow}
      assert {:ok, {:java_ref, :math_pow}} = Analyze.analyze(raw)
    end

    test "Math/abs preserves Java reference identity" do
      raw = {:ns_symbol, :Math, :abs}
      assert {:ok, {:java_ref, :math_abs}} = Analyze.analyze(raw)
    end
  end

  describe "bounded Java interop namespaces" do
    test "Duration/between resolves without exposing bare between" do
      assert {:ok, %{return: 1000}} =
               PtcRunner.Lisp.run(
                 ~s|(.toMillis (Duration/between (Instant/parse "2026-05-22T00:00:00Z") (Instant/parse "2026-05-22T00:00:01Z")))|
               )

      assert {:error, step} =
               PtcRunner.Lisp.run(
                 ~s|(.toMillis (between (Instant/parse "2026-05-22T00:00:00Z") (Instant/parse "2026-05-22T00:00:01Z")))|
               )

      assert step.fail.message =~ "Undefined variable: between"
    end

    test "fully-qualified java.time.Duration/between resolves to the same bounded helper" do
      assert {:ok, %{return: 1000}} =
               PtcRunner.Lisp.run(
                 ~s|(.toMillis (java.time.Duration/between (Instant/parse "2026-05-22T00:00:00Z") (Instant/parse "2026-05-22T00:00:01Z")))|
               )
    end

    test "Java time namespaces do not expose unrelated interop helpers" do
      assert {:error, step} = PtcRunner.Lisp.run("(LocalDate/currentTimeMillis)")
      assert step.fail.message =~ "currentTimeMillis is not available"
      assert step.fail.message =~ "Interop functions: LocalDate/parse"

      assert {:error, step} = PtcRunner.Lisp.run("(Duration/parse \"PT1S\")")
      assert step.fail.message =~ "Duration/parse is not available"
      assert step.fail.message =~ "Duration/between"
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

    test "clojure.core/nonexistent gives helpful error with core functions" do
      raw = {:ns_symbol, :"clojure.core", :nonexistent}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "nonexistent is not available"
      assert msg =~ "Core functions:"
      assert msg =~ "map"
      assert msg =~ "filter"
    end

    test "clojure.set/select gives helpful error with set functions" do
      raw = {:ns_symbol, :"clojure.set", :select}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "select is not available"
      assert msg =~ "Set functions:"
      assert msg =~ "set"
      assert msg =~ "contains?"
    end

    test "clojure.walk/stringify-keys gives helpful error with walk functions" do
      raw = {:ns_symbol, :"clojure.walk", :"stringify-keys"}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "stringify-keys is not available"
      assert msg =~ "Walk functions:"
      assert msg =~ "prewalk"
      assert msg =~ "postwalk"
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

      assert {:error,
              {:invalid_form, msg,
               %{
                 kind: :unknown_namespace,
                 rejected_namespace: "my_ns",
                 available_namespaces: available_namespaces
               }}} = Analyze.analyze(raw)

      assert msg =~ "unknown namespace"
      assert msg =~ "my_ns"
      assert msg =~ "tool/"
      assert available_namespaces == Enum.sort(available_namespaces)
    end

    test "unknown namespace in call position" do
      raw = {:list, [{:ns_symbol, :custom, :func}, {:symbol, :x}]}

      assert {:error,
              {:invalid_form, msg, %{kind: :unknown_namespace, rejected_namespace: "custom"}}} =
               Analyze.analyze(raw)

      assert msg =~ "unknown namespace"
      assert msg =~ "custom"
    end
  end

  describe "data and tool namespaces still work" do
    test "data/input still works as context access" do
      raw = {:ns_symbol, :data, :input}
      assert {:ok, {:data, :input}} = Analyze.analyze(raw)
    end

    test "tool/tool-name in call position still works" do
      raw = {:list, [{:ns_symbol, :tool, :search}, {:map, []}]}
      assert {:ok, {:tool_call, :search, [{:map, []}]}} = Analyze.analyze(raw)
    end
  end

  describe "cross-category builtins are rejected" do
    test "str/map does not normalize to core map" do
      raw = {:ns_symbol, :str, :map}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "map is not available"
      assert msg =~ "String functions:"
    end

    test "core/join does not normalize to string join" do
      raw = {:ns_symbol, :core, :join}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "join is not available"
      assert msg =~ "Core functions:"
    end

    test "set/filter does not normalize to core filter" do
      raw = {:ns_symbol, :set, :filter}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "filter is not available"
      assert msg =~ "Set functions:"
    end

    test "walk/map does not normalize to core map" do
      raw = {:ns_symbol, :walk, :map}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "map is not available"
      assert msg =~ "Walk functions:"
    end

    test "clojure.walk/+ does not normalize to core +" do
      raw = {:ns_symbol, :"clojure.walk", :+}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "+ is not available"
      assert msg =~ "Walk functions:"
    end
  end
end
