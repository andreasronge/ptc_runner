defmodule PtcRunner.Lisp.Java.NumericDispatchTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Analyze
  alias PtcRunner.Lisp.Java.Callable
  alias PtcRunner.Lisp.Java.Primitive
  alias PtcRunner.Lisp.Parser

  test "numeric parsers return their exact Java primitive kinds" do
    assert {:ok, %{return: %Primitive{kind: :int, value: -42}}} =
             Lisp.run_native(~S|(Integer/parseInt "-42")|)

    assert {:ok, %{return: %Primitive{kind: :long, value: 9_223_372_036_854_775_807}}} =
             Lisp.run_native(~S|(Long/parseLong "9223372036854775807")|)

    assert {:ok, %{return: %Primitive{kind: :double, value: 1.5}}} =
             Lisp.run_native(~S|(Double/parseDouble "0x1.8p0")|)

    assert {:ok, %{return: %Primitive{kind: :float, value: 1.5}}} =
             Lisp.run_native(~S|(Float/parseFloat " 1.5 ")|)

    assert {:ok, %{return: [-42, 9_223_372_036_854_775_807, 1.5, 1.5]}} =
             Lisp.run(
               ~S|[(Integer/parseInt "-42") (Long/parseLong "9223372036854775807") | <>
                 ~S|(Double/parseDouble "0x1.8p0") (Float/parseFloat " 1.5 ")]|
             )
  end

  test "Double fields retain double identity natively and project as special numbers" do
    assert {:ok, %{return: %Primitive{kind: :double, value: :infinity}}} =
             Lisp.run_native("Double/POSITIVE_INFINITY")

    assert {:ok, %{return: %Primitive{kind: :double, value: :negative_infinity}}} =
             Lisp.run_native("Double/NEGATIVE_INFINITY")

    assert {:ok, %{return: %Primitive{kind: :double, value: :nan}}} =
             Lisp.run_native("Double/NaN")

    assert {:ok, %{return: [:infinity, :negative_infinity, :nan]}} =
             Lisp.run("[Double/POSITIVE_INFINITY Double/NEGATIVE_INFINITY Double/NaN]")
  end

  test "Double fields are values and cannot be called" do
    for field <- ~w(POSITIVE_INFINITY NEGATIVE_INFINITY NaN) do
      assert {:ok, raw} = Parser.parse("(Double/#{field})")

      assert {:error, {:java_arity_error, reference_id, %{expected: [], actual: 0}}} =
               Analyze.analyze(raw)

      assert reference_id in [
               :double_positive_infinity,
               :double_negative_infinity,
               :double_nan
             ]
    end
  end

  test "numeric parser references are first-class closed callables" do
    for {source, reference_id, expected} <- [
          {"Integer/parseInt", :integer_parse_int, 42},
          {"Long/parseLong", :long_parse_long, 42},
          {"Double/parseDouble", :double_parse_double, 42.0},
          {"Float/parseFloat", :float_parse_float, 42.0}
        ] do
      assert {:ok, %{return: %Callable{reference_id: ^reference_id}}} = Lisp.run_native(source)
      assert {:ok, %{return: ^expected}} = Lisp.run("(#{source} \"42\")")
      assert {:ok, %{return: ^expected}} = Lisp.run("(apply #{source} [\"42\"])")
    end
  end

  test "Java numeric parser failures are bounded and class-specific" do
    for source <- [
          ~S|(Integer/parseInt "2147483648")|,
          ~S|(Long/parseLong "9223372036854775808")|,
          ~S|(Double/parseDouble "not-a-double")|,
          ~S|(Float/parseFloat "")|
        ] do
      assert {:error, step} = Lisp.run(source)
      assert step.fail.reason == :java_domain_error
      assert step.fail.details.java_exception == :number_format_exception
    end

    for source <- ["(Double/parseDouble nil)", "(Float/parseFloat nil)"] do
      assert {:error, step} = Lisp.run(source)
      assert step.fail.reason == :java_domain_error
      assert step.fail.details.java_exception == :null_pointer_exception
    end

    assert {:error, step} = Lisp.run("(Integer/parseInt nil)")
    assert step.fail.reason == :java_domain_error
    assert step.fail.details.java_exception == :number_format_exception

    assert {:error, %{fail: %{reason: :java_type_error}}} =
             Lisp.run("(Long/parseLong 42)")
  end

  test "Clojure-named safe parsers keep signal-value semantics" do
    assert {:ok, %{return: [nil, nil]}} =
             Lisp.run(~S|[(parse-long "bad") (parse-double "bad")]|)
  end

  test "floating parsers round Java boundary syntax directly to their declared kind" do
    assert {:ok, %{return: %Primitive{kind: :double, value: 1.797_693_134_862_315_7e308}}} =
             Lisp.run_native(~S|(Double/parseDouble "1.7976931348623157e308")|)

    assert {:ok, %{return: %Primitive{kind: :double, value: :infinity}}} =
             Lisp.run_native(~S|(Double/parseDouble "1.7976931348623159e308")|)

    assert {:ok, %{return: %Primitive{kind: :double, value: 5.0e-324}}} =
             Lisp.run_native(~S|(Double/parseDouble "0x0.0000000000001p-1022")|)

    assert {:ok, %{return: %Primitive{kind: :float, value: 3.402_823_466_385_288_6e38}}} =
             Lisp.run_native(~S|(Float/parseFloat "3.4028235e38f")|)

    assert {:ok, %{return: %Primitive{kind: :float, value: :infinity}}} =
             Lisp.run_native(~S|(Float/parseFloat "3.4028236e38")|)

    assert {:ok, %{return: %Primitive{kind: :float, value: 1.401298464324817e-45}}} =
             Lisp.run_native(~S|(Float/parseFloat "1.4e-45")|)

    assert {:ok, %{return: %Primitive{kind: :double, value: negative_zero}}} =
             Lisp.run_native(~S|(Double/parseDouble "-0")|)

    assert <<1::1, 0::63>> = <<negative_zero::float-64>>
  end

  test "floating parsers ignore zero padding in decimal and hexadecimal exponents" do
    for {function, expected_values} <- [
          {"Double/parseDouble", [10.0, 0.1, 2.0, 0.5]},
          {"Float/parseFloat", [10.0, 0.10000000149011612, 2.0, 0.5]}
        ] do
      for {input, expected} <-
            Enum.zip(~w(1e0000001 1e-0000001 0x1p0000001 0x1p-0000001), expected_values) do
        assert {:ok, %{return: %Primitive{value: ^expected}}} =
                 Lisp.run_native(~s|(#{function} "#{input}")|)
      end
    end
  end

  test "floating parsers preserve exponent cancellation in large valid literals" do
    input = "0x0." <> String.duplicate("0", 250_000) <> "1p1000004"

    assert {:ok, %{return: %Primitive{kind: :double, value: 1.0}}} =
             Lisp.run_native("(Double/parseDouble data/value)",
               context: %{"value" => input},
               filter_context: false
             )
  end

  test "integer parsers admit exactly their decimal primitive ranges" do
    assert {:ok, %{return: %Primitive{kind: :int, value: -2_147_483_648}}} =
             Lisp.run_native(~S|(Integer/parseInt "-2147483648")|)

    assert {:ok, %{return: %Primitive{kind: :int, value: 2_147_483_647}}} =
             Lisp.run_native(~S|(Integer/parseInt "+2147483647")|)

    assert {:ok, %{return: %Primitive{kind: :long, value: -9_223_372_036_854_775_808}}} =
             Lisp.run_native(~S|(Long/parseLong "-9223372036854775808")|)

    assert {:ok, %{return: %Primitive{kind: :int, value: 12}}} =
             Lisp.run_native(~S|(Integer/parseInt "١٢")|)

    assert {:ok, %{return: %Primitive{kind: :long, value: 12}}} =
             Lisp.run_native(~S|(Long/parseLong "１２")|)

    assert {:error, %{fail: %{reason: :java_domain_error}}} =
             Lisp.run(~S|(Integer/parseInt " 1")|)
  end
end
