defmodule PtcRunner.Lisp.Runtime.StringStrTest do
  use ExUnit.Case, async: true

  defp run!(code) do
    {:ok, step} = PtcRunner.Lisp.run(code, context: %{})
    step.return
  end

  describe "(str) with single non-string argument" do
    test "converts a map to string" do
      assert is_binary(run!("(str {:a 1})"))
    end

    test "converts a list to string" do
      assert is_binary(run!("(str [1 2 3])"))
    end

    test "converts an integer to string" do
      assert run!("(str 42)") == "42"
    end

    test "converts nil to empty string" do
      assert run!("(str nil)") == ""
    end

    test "returns a string unchanged" do
      assert run!("(str \"hello\")") == "hello"
    end
  end
end
