defmodule PtcRunner.Lisp.Java.SystemDispatchTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Java.Callable
  alias PtcRunner.Lisp.Java.Primitive

  test "System/currentTimeMillis is a closed callable that preserves Java long identity" do
    before_ms = System.system_time(:millisecond)

    assert {:ok, %{return: %Callable{reference_id: :system_current_time_millis}}} =
             Lisp.run_native("System/currentTimeMillis")

    assert {:ok,
            %{
              return: [
                %Primitive{kind: :long, value: direct_ms},
                %Primitive{kind: :long, value: applied_ms},
                %Primitive{kind: :long, value: qualified_ms}
              ]
            }} =
             Lisp.run_native(
               "[(System/currentTimeMillis) " <>
                 "(apply System/currentTimeMillis []) " <>
                 "(java.lang.System/currentTimeMillis)]"
             )

    after_ms = System.system_time(:millisecond)

    for value <- [direct_ms, applied_ms, qualified_ms] do
      assert value >= before_ms
      assert value <= after_ms
    end
  end

  test "System time projects as an ordinary integer and has no bare compatibility alias" do
    assert {:ok, %{return: value}} = Lisp.run("(System/currentTimeMillis)")
    assert is_integer(value)

    assert {:error, step} = Lisp.run("(currentTimeMillis)")
    assert step.fail.message =~ "Undefined variable: currentTimeMillis"
  end
end
