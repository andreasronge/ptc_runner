defmodule PtcRunner.Lisp.Java.DispatchTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Analyze
  alias PtcRunner.Lisp.DataKeys
  alias PtcRunner.Lisp.Java.Callable
  alias PtcRunner.Lisp.Java.Dispatch
  alias PtcRunner.Lisp.Parser

  def handle_dispatch_attestation(_event, _measurements, metadata, test_pid),
    do: send(test_pid, {:java_dispatch, metadata})

  describe "class-aware Boolean analysis" do
    test "preserves static invocation identity for short and fully-qualified spellings" do
      for source <- [
            ~S|(Boolean/parseBoolean "true")|,
            ~S|(java.lang.Boolean/parseBoolean "true")|
          ] do
        assert {:ok, raw} = Parser.parse(source)

        assert {:ok, {:java_static, :boolean_parse_boolean, [{:string, "true"}]}} =
                 Analyze.analyze(raw)
      end
    end

    test "preserves an admitted Java reference in value position" do
      assert {:ok, raw} = Parser.parse("Boolean/parseBoolean")
      assert {:ok, {:java_ref, :boolean_parse_boolean}} = Analyze.analyze(raw)
    end

    test "rejects a statically impossible arity" do
      assert {:ok, raw} = Parser.parse("(Boolean/parseBoolean)")

      assert {:error, {:java_arity_error, :boolean_parse_boolean, %{expected: [1], actual: 0}}} =
               Analyze.analyze(raw)
    end

    test "distinguishes unsupported Java classes and members" do
      assert {:ok, raw} = Parser.parse("(java.lang.Thread/sleep 1)")
      assert {:error, {:unsupported_java_class, "java.lang.Thread"}} = Analyze.analyze(raw)

      assert {:ok, raw} = Parser.parse("(Boolean/missing 1)")
      assert {:error, {:unsupported_java_member, :Boolean, "missing"}} = Analyze.analyze(raw)
    end

    test "rejects removed non-Java Math namespace aliases" do
      for {source, member} <- [
            {"(Math/bit-and 7 3)", :"bit-and"},
            {"(java.lang.Math/bit-and 7 3)", :"bit-and"},
            {"(Math/trunc 3.9)", :trunc},
            {"(java.lang.Math/trunc 3.9)", :trunc}
          ] do
        assert {:ok, raw} = Parser.parse(source)

        assert {:error, {:unsupported_java_member, _class, ^member}} =
                 Analyze.analyze(raw)
      end

      assert {:ok, %{return: 3}} = Lisp.run("(bit-and 7 3)")
      assert {:ok, %{return: 3}} = Lisp.run("(trunc 3.9)")
    end
  end

  describe "closed Boolean dispatch" do
    test "constructs callables only for admitted references" do
      assert {:ok, %Callable{reference_id: :boolean_parse_boolean}} =
               Callable.new(:boolean_parse_boolean)

      assert {:ok, %Callable{reference_id: :double_parse_double}} =
               Callable.new(:double_parse_double)

      assert {:ok, %Callable{reference_id: :math_abs}} = Callable.new(:math_abs)
      assert Callable.valid?(%Callable{reference_id: :math_abs})
    end

    test "reports the selected manifest overload without exposing it as Lisp data" do
      assert {:ok, true, :boolean_parse_boolean_string} =
               Dispatch.invoke(:boolean_parse_boolean, :static, nil, ["TrUe"])

      assert {:ok, false, :boolean_parse_boolean_string} =
               Dispatch.invoke(:boolean_parse_boolean, :static, nil, [nil])
    end

    test "first-class callables derive invocation kind from their admitted reference" do
      assert {:ok, callable} = Callable.new(:boolean_parse_boolean)

      assert {:ok, true, :boolean_parse_boolean_string} =
               Callable.invoke(callable, ["true"])
    end

    test "emits a test-observable selected-overload attestation" do
      handler_id = {__MODULE__, self(), make_ref()}
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:ptc_runner, :lisp, :java, :dispatch],
          &__MODULE__.handle_dispatch_attestation/4,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{return: true}} = Lisp.run_native(~S|(Boolean/parseBoolean "true")|)

      assert_receive {:java_dispatch,
                      %{
                        reference_id: :boolean_parse_boolean,
                        overload_id: :boolean_parse_boolean_string
                      }}
    end

    test "rejects invalid argument types before invoking the handler" do
      assert {:error, condition} =
               Dispatch.invoke(:boolean_parse_boolean, :static, nil, [true])

      assert condition.category == :java_type_error
      assert condition.reference_id == :boolean_parse_boolean
      assert condition.overload_id == nil
      assert condition.details == %{argument: 0, expected: [:string], actual: :boolean}
    end

    test "validates handler postconditions against the selected overload" do
      assert {:error, condition} =
               Dispatch.validate_handler_outcome(
                 :boolean_parse_boolean_string,
                 {:ok, "not-a-boolean"}
               )

      assert condition.category == :java_handler_contract_error
      assert condition.overload_id == :boolean_parse_boolean_string
    end

    test "rejects untagged integers outside Java long range" do
      min = -9_223_372_036_854_775_808
      max = 9_223_372_036_854_775_807

      assert {:ok, ^min, 2} = Dispatch.coerce_argument(:long, min)
      assert {:ok, ^max, 2} = Dispatch.coerce_argument(:long, max)
      assert :error = Dispatch.coerce_argument(:long, min - 1)
      assert :error = Dispatch.coerce_argument(:long, max + 1)
    end
  end

  describe "Boolean execution paths" do
    test "direct calls agree in native and public execution" do
      assert {:ok, %{return: true}} = Lisp.run_native(~S|(Boolean/parseBoolean "TRUE")|)
      assert {:ok, %{return: true}} = Lisp.run(~S|(Boolean/parseBoolean "TRUE")|)
    end

    test "value-position references remain native and project to an inert label" do
      assert {:ok, %{return: %Callable{reference_id: :boolean_parse_boolean}}} =
               Lisp.run_native("Boolean/parseBoolean")

      assert {:ok, %{return: "#java[java.lang.Boolean/parseBoolean]"}} =
               Lisp.run("Boolean/parseBoolean")

      assert {:ok,
              %{
                memory: %{"parser" => "#java[java.lang.Boolean/parseBoolean]"}
              }} = Lisp.run("(def parser Boolean/parseBoolean)")
    end

    test "Java references are first-class callables through higher-order and apply paths" do
      assert {:ok, %{return: [true, false, false]}} =
               Lisp.run(~S|(map Boolean/parseBoolean ["TRUE" "no" nil])|)

      assert {:ok, %{return: true}} =
               Lisp.run(~S|(apply Boolean/parseBoolean ["true"])|)

      assert {:ok, %{return: true}} =
               Lisp.run(~S|((fnil Boolean/parseBoolean "true") nil)|)

      assert {:ok, %{return: [true, false]}} =
               Lisp.run(~S|(pmap Boolean/parseBoolean ["true" "false"])|)

      assert {:ok, %{return: true}} =
               Lisp.run(~S|((let [value "true"] (fn [] (Boolean/parseBoolean value))))|)
    end

    test "invalid arity and type are bounded Java failures" do
      assert {:error, arity_step} =
               Lisp.run(~S|((fn [f] (f)) Boolean/parseBoolean)|)

      assert arity_step.fail.reason == :java_arity_error

      assert arity_step.fail.details == %{
               actual: 0,
               expected: [1],
               reference_id: :boolean_parse_boolean
             }

      assert {:error, step} = Lisp.run("(Boolean/parseBoolean true)")
      assert step.fail.reason == :java_type_error

      assert step.fail.details == %{
               actual: :boolean,
               argument: 0,
               expected: [:string],
               reference_id: :boolean_parse_boolean
             }
    end
  end

  test "CoreAST consumers recurse through Java arguments" do
    ast =
      {:java_static, :boolean_parse_boolean,
       [
         {:call, {:var, :str}, [{:data, :input}, {:var, :missing}]}
       ]}

    assert DataKeys.extract(ast) == MapSet.new([:input])
    assert Lisp.undefined_vars(ast, MapSet.new()) == ["missing"]

    assert {:error, %{fail: %{reason: :unknown_tool}}} =
             Lisp.run(~S|(Boolean/parseBoolean (tool/missing {}))|)
  end
end
