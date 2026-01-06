defmodule PtcRunner.Lisp.RangeArityTest do
  use ExUnit.Case
  alias PtcRunner.Lisp

  test "range with 0 arguments fails with clear error" do
    source = "(range)"

    assert {:error, %PtcRunner.Step{fail: %{reason: :arity_error, message: message}}} =
             Lisp.run(source)

    assert message =~ "expected arity [1, 2, 3], got 0"
  end
end
