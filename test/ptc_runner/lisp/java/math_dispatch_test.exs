defmodule PtcRunner.Lisp.Java.MathDispatchTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Java.Callable
  alias PtcRunner.Lisp.Java.Primitive

  test "Math references are native Java callables and preserve selected primitive kinds" do
    for {source, reference_id} <- [
          {"Math/abs", :math_abs},
          {"Math/ceil", :math_ceil},
          {"Math/floor", :math_floor},
          {"Math/max", :math_max},
          {"Math/min", :math_min},
          {"Math/pow", :math_pow},
          {"Math/round", :math_round},
          {"Math/sqrt", :math_sqrt}
        ] do
      assert {:ok, %{return: %Callable{reference_id: ^reference_id}}} = Lisp.run_native(source)
    end

    assert {:ok,
            %{
              return: [
                %Primitive{kind: :int, value: -2_147_483_648},
                %Primitive{kind: :long, value: -9_223_372_036_854_775_808},
                %Primitive{kind: :float, value: float_zero},
                %Primitive{kind: :double, value: 7.0}
              ]
            }} =
             Lisp.run_native(~S|[(Math/abs (Integer/parseInt "-2147483648"))
                   (Math/abs (Long/parseLong "-9223372036854775808"))
                   (Math/abs (Float/parseFloat "-0.0"))
                   (Math/abs -7.0)]|)

    assert <<0::1, 0::63>> = <<float_zero::float-64>>
  end

  test "Math overload identity survives storage, collections, apply, and map" do
    assert {:ok,
            %{
              return: [
                %Primitive{kind: :int, value: 7},
                %Primitive{kind: :long, value: 9},
                [%Primitive{kind: :float, value: 1.5}]
              ]
            }} =
             Lisp.run_native(~S|(let [i (Integer/parseInt "-7")
                        l (Long/parseLong "-9")
                        fs [(Float/parseFloat "-1.5")]]
                    [(apply Math/abs [i])
                     (Math/abs l)
                     (map Math/abs fs)])|)
  end

  test "Math min and max use Java arity, type, NaN, and signed-zero semantics" do
    for source <- ["(Math/max 1)", "(Math/min 1 2 3)"] do
      assert {:error, step} = Lisp.run(source)
      assert step.fail.reason == :java_arity_error
    end

    for source <- ["(Math/max 1 2.0)", "(Math/min nil 1)", ~S|(Math/max "a" 1)|] do
      assert {:error, step} = Lisp.run(source)
      assert step.fail.reason == :java_type_error
    end

    assert {:error, mixed} = Lisp.run("(Math/max 1 2.0)")

    assert mixed.fail.details == %{
             actual: [:integer, :float],
             expected: [[:int, :int], [:long, :long], [:float, :float], [:double, :double]],
             reference_id: :math_max
           }

    assert {:ok,
            %{
              return: [
                %Primitive{kind: :double, value: positive_zero},
                %Primitive{kind: :double, value: negative_zero},
                %Primitive{kind: :double, value: :nan}
              ]
            }} =
             Lisp.run_native("[(Math/max -0.0 0.0) (Math/min 0.0 -0.0) (Math/max ##NaN 1.0)]")

    assert <<0::1, 0::63>> = <<positive_zero::float-64>>
    assert <<1::1, 0::63>> = <<negative_zero::float-64>>
  end

  test "Math ceil, floor, round, pow, and sqrt keep Java result shapes" do
    assert {:ok,
            %{
              return: [
                %Primitive{kind: :double, value: 2.0},
                %Primitive{kind: :double, value: -2.0},
                %Primitive{kind: :long, value: -1},
                %Primitive{kind: :int, value: -1},
                %Primitive{kind: :long, value: 0},
                %Primitive{kind: :long, value: 9_223_372_036_854_775_807},
                %Primitive{kind: :long, value: 4_503_599_627_370_497},
                %Primitive{kind: :double, value: 8.0},
                %Primitive{kind: :double, value: 5.0}
              ]
            }} =
             Lisp.run_native(~S|[(Math/ceil 1.2)
                   (Math/floor -1.2)
                   (Math/round -1.5)
                   (Math/round (Float/parseFloat "-1.5"))
                   (Math/round ##NaN)
                   (Math/round ##Inf)
                   (Math/round 4503599627370497.0)
                   (Math/pow 2 3)
                   (Math/sqrt 25)]|)

    assert {:ok, %{return: ["2.0", "-2.0"]}} =
             Lisp.run("[(str (Math/ceil 1.2)) (str (Math/floor -1.2))]")

    assert {:error, %{fail: %{reason: :java_type_error}}} = Lisp.run("(Math/round 1)")
  end

  test "a sole double overload converts each numeric argument independently" do
    assert {:ok,
            %{
              return: [
                %Primitive{kind: :double, value: :nan},
                %Primitive{kind: :double, value: :nan},
                %Primitive{kind: :double, value: :negative_infinity}
              ]
            }} =
             Lisp.run_native("[(Math/pow -1 0.5) (Math/pow 1 ##Inf) (Math/pow -0.0 -3)]")
  end

  test "sole-double fallback errors diagnose the coercions used during selection" do
    assert {:error, pow_error} = Lisp.run(~S|(Math/pow 2 "x")|)

    assert pow_error.fail.details == %{
             argument: 1,
             actual: :string,
             expected: [:double],
             reference_id: :math_pow
           }
  end

  test "overload-combination errors classify admitted Java numeric specials" do
    assert {:error, max_error} = Lisp.run("(Math/max ##NaN 1)")

    assert max_error.fail.details == %{
             actual: [:double, :integer],
             expected: [[:int, :int], [:long, :long], [:float, :float], [:double, :double]],
             reference_id: :math_max
           }
  end

  test "qualified Math rejects out-of-range integers while bare PTC math remains unchanged" do
    assert {:error, %{fail: %{reason: :java_type_error}}} =
             Lisp.run("(Math/abs 9223372036854775808)")

    assert {:ok, %{return: [1, 3, -2, 2, 9_223_372_036_854_775_808]}} =
             Lisp.run(
               "[(max 1) (max 1 2 3) (round -1.5) (ceil 1.2) " <>
                 "(abs -9223372036854775808)]"
             )
  end
end
