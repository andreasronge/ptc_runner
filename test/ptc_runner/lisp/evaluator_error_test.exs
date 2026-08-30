defmodule PtcRunner.Lisp.EvaluatorErrorTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.EvaluatorError
  alias PtcRunner.Lisp.EvaluatorErrorCatalog

  test "public evidence uses admitted arithmetic tokens rather than raw messages" do
    assert {:ok, %{kind: "arithmetic_error", message: "division by zero"}} =
             EvaluatorError.public_evidence(:arithmetic_error, %{token: :division_by_zero})

    assert EvaluatorError.public_evidence(:arithmetic_error, %{
             token: :division_by_zero,
             message: "&PtcRunner.Lisp.Runtime.divide/2"
           }) ==
             EvaluatorError.public_evidence(:arithmetic_error, %{token: :division_by_zero})

    assert EvaluatorError.public_evidence(:arithmetic_error, %{message: "division by zero"}) ==
             :error
  end

  test "arity evidence uses the public Lisp name and never a BEAM MFA" do
    assert {:ok, %{kind: "arity_error", message: "count expects 1 argument(s), got 0"}} =
             EvaluatorError.public_evidence(:arity_error, %{
               name: "count",
               expected: 1,
               actual: 0
             })

    assert EvaluatorError.public_evidence(:arity_error, %{
             name: "&PtcRunner.Lisp.Runtime.count/1",
             expected: 1,
             actual: 0
           }) == :error
  end

  test "not_callable does not echo an arbitrary rejected value" do
    assert {:ok, %{kind: "not_callable", message: "value is not callable"}} =
             EvaluatorError.public_evidence(:not_callable, %{})

    assert {:ok, %{kind: "not_callable", message: "tickets is not callable"}} =
             EvaluatorError.public_evidence(:not_callable, %{name: "tickets"})

    assert {:ok, %{kind: "not_callable", message: "value is not callable"}} =
             EvaluatorError.public_evidence(:not_callable, %{name: "%{secret: 1}"})
  end

  test "loop_limit_exceeded retains the admitted bound and remedy" do
    assert {:ok,
            %{
              kind: "loop_limit_exceeded",
              message:
                "Loop iteration limit exceeded (1000 iterations). Reduce the iterations in this loop, split the work into separately entered loops, use a finite collection operation, or raise the active configured limit."
            }} =
             EvaluatorError.public_evidence(:loop_limit_exceeded, %{limit: 1000})
  end

  test "Java kinds publish catalog messages without reference or overload IDs" do
    assert {:ok, %{kind: "java_type_error", message: message}} =
             EvaluatorError.public_evidence(:java_type_error, %{
               reference_id: :some_ref,
               overload_id: :overload_3,
               value: "secret"
             })

    refute message =~ "some_ref"
    refute message =~ "overload_3"
    refute message =~ "secret"
  end

  test "an admitted Java member spelling survives while arbitrary detail is dropped" do
    assert {:ok,
            %{
              kind: "unsupported_java_member",
              message: "Java member .isBefore does not accept this receiver"
            }} =
             EvaluatorError.public_evidence(:unsupported_java_member, %{
               name: ".isBefore",
               receiver_profile: :unsupported,
               secret: "nope"
             })

    assert {:ok, {:unsupported_java_member, %{name: ".isBefore"}}} =
             EvaluatorError.retain_reason(
               {:unsupported_java_member, %{name: ".isBefore", secret: "nope"}}
             )

    assert {:ok, %{message: "Java member is outside the admitted interop surface"}} =
             EvaluatorError.public_evidence(:unsupported_java_member, %{name: ".bad/name"})
  end

  test "unknown reasons fail closed" do
    assert EvaluatorError.public_evidence(:explicit_failure, %{}) == :error
    assert EvaluatorError.public_evidence(:unbound_var, %{name: "x"}) == :error
    assert :timeout not in EvaluatorErrorCatalog.kinds()
  end

  test "retain_reason keeps catalogued evaluator tuples and drops unadmitted payloads" do
    assert {:ok, {:arithmetic_error, :division_by_zero}} =
             EvaluatorError.retain_reason({:arithmetic_error, :division_by_zero})

    assert {:ok, {:arity_error, %{name: "count", expected: 1, actual: 0}}} =
             EvaluatorError.retain_reason(
               {:arity_error, %{name: "count", expected: 1, actual: 0, secret: "nope"}}
             )

    assert {:ok, {:not_callable, %{}}} =
             EvaluatorError.retain_reason({:not_callable, ["SECRET"]})

    assert {:ok,
            {:java_type_error, "Java member argument does not match an admitted overload", %{}}} =
             EvaluatorError.retain_reason(
               {:java_type_error, "overload_3 SECRET",
                %{reference_id: :r, overload_id: :overload_3}}
             )

    assert EvaluatorError.retain_reason({:explicit_failure, %{"secret" => true}}) == :error
  end

  test "Java arity retention drops hostile arity details" do
    for expected <- [%{"secret" => true}, List.duplicate(1, 33), [1 | :improper]] do
      assert {:ok, {:java_arity_error, %{name: ".length"}}} =
               EvaluatorError.retain_reason(
                 {:java_arity_error, %{name: ".length", expected: expected, actual: "SECRET"}}
               )
    end
  end
end
