defmodule PtcRunner.Lisp.DoubleConstantsTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Format

  describe "double constants resolution" do
    test "resolves namespaced constants" do
      assert {:ok, %{return: :infinity}} = Lisp.run("Double/POSITIVE_INFINITY")
      assert {:ok, %{return: :negative_infinity}} = Lisp.run("Double/NEGATIVE_INFINITY")
      assert {:ok, %{return: :nan}} = Lisp.run("Double/NaN")
    end

    test "resolves special literals" do
      assert {:ok, %{return: :infinity}} = Lisp.run("##Inf")
      assert {:ok, %{return: :negative_infinity}} = Lisp.run("##-Inf")
      assert {:ok, %{return: :nan}} = Lisp.run("##NaN")
    end

    test "arithmetic with constants" do
      assert {:ok, %{return: :infinity}} = Lisp.run("(+ Double/POSITIVE_INFINITY 1)")

      assert {:ok, %{return: :nan}} =
               Lisp.run("(- Double/POSITIVE_INFINITY Double/POSITIVE_INFINITY)")

      assert {:ok, %{return: :nan}} = Lisp.run("(* Double/NaN 10)")
      assert {:ok, %{return: :infinity}} = Lisp.run("(/ 1.0 0.0)")
    end

    test "predicates and comparisons" do
      assert {:ok, %{return: true}} = Lisp.run("(number? Double/POSITIVE_INFINITY)")
      assert {:ok, %{return: true}} = Lisp.run("(pos? Double/POSITIVE_INFINITY)")
      assert {:ok, %{return: false}} = Lisp.run("(= Double/NaN Double/NaN)")
      assert {:ok, %{return: true}} = Lisp.run("(< 1000 Double/POSITIVE_INFINITY)")
      assert {:ok, %{return: true}} = Lisp.run("(> 1000 Double/NEGATIVE_INFINITY)")
      assert {:ok, %{return: true}} = Lisp.run("(< Double/NEGATIVE_INFINITY -1000)")

      # NaN comparisons (all should be false)
      assert {:ok, %{return: false}} = Lisp.run("(< Double/NaN 0)")
      assert {:ok, %{return: false}} = Lisp.run("(> Double/NaN 0)")
      assert {:ok, %{return: false}} = Lisp.run("(<= Double/NaN 0)")
      assert {:ok, %{return: false}} = Lisp.run("(>= Double/NaN 0)")

      assert {:ok, %{return: :infinity}} = Lisp.run("(parse-double \"+Infinity\")")
    end

    test "Double/parseDouble aliases parse-double" do
      assert {:ok, %{return: 11.76}} = Lisp.run(~S|(Double/parseDouble "11.760000")|)
      assert {:ok, %{return: nil}} = Lisp.run(~S|(Double/parseDouble "not-a-number")|)
    end

    test "Java parse aliases use parse semantics for their target classes" do
      assert {:ok, %{return: true}} = Lisp.run(~S|(Boolean/parseBoolean "true")|)
      assert {:ok, %{return: true}} = Lisp.run(~S|(Boolean/parseBoolean "TRUE")|)
      assert {:ok, %{return: true}} = Lisp.run(~S|(Boolean/parseBoolean "TrUe")|)
      assert {:ok, %{return: false}} = Lisp.run(~S|(Boolean/parseBoolean "false")|)
      assert {:ok, %{return: false}} = Lisp.run(~S|(Boolean/parseBoolean "yes")|)
      assert {:ok, %{return: false}} = Lisp.run(~S|(Boolean/parseBoolean "")|)
      assert {:ok, %{return: false}} = Lisp.run(~S|(Boolean/parseBoolean nil)|)
      assert {:error, %{fail: %{reason: :type_error}}} = Lisp.run(~S|(Boolean/parseBoolean true)|)

      assert {:ok, %{return: 11.76}} = Lisp.run(~S|(Float/parseFloat "11.760000")|)
      assert {:ok, %{return: nil}} = Lisp.run(~S|(Float/parseFloat "not-a-number")|)

      assert {:ok, %{return: 42}} = Lisp.run(~S|(Integer/parseInt "42")|)
      assert {:ok, %{return: nil}} = Lisp.run(~S|(Integer/parseInt "42.5")|)

      assert {:ok, %{return: 42}} = Lisp.run(~S|(Long/parseLong "42")|)
      assert {:ok, %{return: nil}} = Lisp.run(~S|(Long/parseLong "bad")|)
    end

    test "Java parse alias namespaces are known for diagnostics" do
      for ns <- ~w(Boolean Float Integer Long) do
        assert {:error, %{fail: %{message: msg}}} = Lisp.run("(#{ns}/missing \"42\")")
        assert msg =~ "missing is not available"
        assert msg =~ "Interop functions:"
        refute msg =~ "unknown namespace"
      end
    end

    test "formatting" do
      assert {:ok, %{return: result}} = Lisp.run("Double/POSITIVE_INFINITY")
      assert Format.to_clojure(result) == {"##Inf", false}

      assert {:ok, %{return: result}} = Lisp.run("Double/NaN")
      assert Format.to_clojure(result) == {"##NaN", false}
    end

    test "coercion errors" do
      assert {:error, %{fail: %{reason: :arithmetic_error}}} =
               Lisp.run("(int Double/POSITIVE_INFINITY)")

      assert {:ok, %{return: 0}} = Lisp.run("(int Double/NaN)")
    end
  end
end
