defmodule PtcRunner.Lisp.Runtime.NameKeywordTest do
  use ExUnit.Case, async: true

  defp run!(code) do
    {:ok, step} = PtcRunner.Lisp.run(code, context: %{})
    step.return
  end

  describe "(name)" do
    test "keyword returns name string" do
      assert run!(~s|(name :foo)|) == "foo"
    end

    test "string returns itself" do
      assert run!(~s|(name "bar")|) == "bar"
    end

    test "nil raises error" do
      assert {:error, step} = PtcRunner.Lisp.run(~s|(name nil)|, context: %{})
      assert step.fail.message =~ "name not supported"
    end

    test "number raises error" do
      assert {:error, step} = PtcRunner.Lisp.run(~s|(name 42)|, context: %{})
      assert step.fail.message =~ "name not supported"
    end

    test "special value raises error" do
      assert {:error, step} = PtcRunner.Lisp.run(~s|(name ##Inf)|, context: %{})
      assert step.fail.message =~ "name not supported"
    end
  end

  describe "(keyword)" do
    test "string to keyword" do
      assert run!(~s|(= :foo (keyword "foo"))|) == true
    end

    test "keyword returns itself" do
      assert run!(~s|(= :bar (keyword :bar))|) == true
    end

    test "nil returns nil" do
      assert run!(~s|(keyword nil)|) == nil
    end

    test "keyword? on result is true" do
      assert run!(~s|(keyword? (keyword "test"))|) == true
    end

    test "roundtrip: keyword of name" do
      assert run!(~s|(= :hello (keyword (name :hello)))|) == true
    end

    test "empty string raises error" do
      assert {:error, step} = PtcRunner.Lisp.run(~s|(keyword "")|, context: %{})
      assert step.fail.message =~ "invalid keyword name"
    end

    test "string with slash raises error (DIV-13)" do
      assert {:error, step} = PtcRunner.Lisp.run(~s|(keyword "foo/bar")|, context: %{})
      assert step.fail.message =~ "invalid keyword name"
    end

    test "string with space raises error" do
      assert {:error, step} = PtcRunner.Lisp.run(~s|(keyword "a b")|, context: %{})
      assert step.fail.message =~ "invalid keyword name"
    end

    test "operator chars are rejected" do
      for char <- ["+", "*", "<", ">", "="] do
        assert {:error, step} = PtcRunner.Lisp.run(~s|(keyword "#{char}")|, context: %{})
        assert step.fail.message =~ "invalid keyword name"
      end
    end

    test "special value ##Inf raises error" do
      assert {:error, step} = PtcRunner.Lisp.run(~s|(keyword ##Inf)|, context: %{})
      assert step.fail.message =~ "cannot coerce special value"
    end

    test "special value ##NaN raises error" do
      assert {:error, step} = PtcRunner.Lisp.run(~s|(keyword ##NaN)|, context: %{})
      assert step.fail.message =~ "cannot coerce special value"
    end

    test "special value ##-Inf raises error" do
      assert {:error, step} = PtcRunner.Lisp.run(~s|(keyword ##-Inf)|, context: %{})
      assert step.fail.message =~ "cannot coerce special value"
    end

    test "unknown atom string raises error" do
      # A string that passes validation but has no existing atom
      assert {:error, step} =
               PtcRunner.Lisp.run(~s|(keyword "zzxxyywwnotexist")|, context: %{})

      assert step.fail.message =~ "keyword not found"
    end
  end
end
