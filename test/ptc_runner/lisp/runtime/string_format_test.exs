defmodule PtcRunner.Lisp.Runtime.StringFormatTest do
  use ExUnit.Case, async: true

  defp run!(code) do
    {:ok, step} = PtcRunner.Lisp.run(code, context: %{})
    step.return
  end

  describe "(format) basic specifiers" do
    test "%s with string" do
      assert run!(~s|(format "Hello %s" "world")|) == "Hello world"
    end

    test "%d with integer" do
      assert run!(~s|(format "%d items" 5)|) == "5 items"
    end

    test "%f with default precision" do
      assert run!(~s|(format "%f" 3.14)|) == "3.140000"
    end

    test "%.2f with precision" do
      assert run!(~s|(format "%.2f" 3.14159)|) == "3.14"
    end

    test "multiple specifiers" do
      assert run!(~s|(format "%s has %d items" "Alice" 5)|) == "Alice has 5 items"
    end

    test "%% literal percent" do
      assert run!(~s|(format "100%%")|) == "100%"
    end

    test "%s with nil produces empty string" do
      assert run!(~s|(format "%s" nil)|) == ""
    end

    test "%x hex" do
      assert run!(~s|(format "%x" 255)|) == "ff"
    end

    test "%o octal" do
      assert run!(~s|(format "%o" 8)|) == "10"
    end

    test "%e scientific notation" do
      result = run!(~s|(format "%.2e" 1500.0)|)
      assert result == "1.50e+03"
    end
  end

  describe "(format) special numeric values" do
    test "%s with ##Inf" do
      assert run!(~s|(format "%s" ##Inf)|) == "Infinity"
    end

    test "%s with ##-Inf" do
      assert run!(~s|(format "%s" ##-Inf)|) == "-Infinity"
    end

    test "%s with ##NaN" do
      assert run!(~s|(format "%s" ##NaN)|) == "NaN"
    end

    test "%f with ##Inf" do
      assert run!(~s|(format "%f" ##Inf)|) == "Infinity"
    end

    test "%e with ##-Inf" do
      assert run!(~s|(format "%e" ##-Inf)|) == "-Infinity"
    end

    test "%d with ##Inf raises error" do
      assert {:error, step} = PtcRunner.Lisp.run(~s|(format "%d" ##Inf)|, context: %{})
      assert step.fail.message =~ "%d expects an integer"
    end
  end

  describe "(format) errors" do
    test "%d with string raises error" do
      assert {:error, step} = PtcRunner.Lisp.run(~s|(format "%d" "not a number")|, context: %{})
      assert step.fail.message =~ "%d expects an integer"
    end

    test "too few args raises error" do
      assert {:error, _step} = PtcRunner.Lisp.run(~s|(format "%s %s" "only one")|, context: %{})
    end

    test "no format string raises error" do
      assert {:error, _step} = PtcRunner.Lisp.run(~s|(format)|, context: %{})
    end
  end
end
