defmodule PtcRunner.Kernel.PrivateDiagnosticTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.PrivateDiagnostic

  @redacted PrivateDiagnostic.redacted_message()

  test "rebuilds an unbound-variable diagnostic from names present in the source" do
    assert {message, false} =
             PrivateDiagnostic.project(
               :unbound_var,
               %{unbound_names: ["defn-", "g", "x"]},
               "(defn- g [x] (* x 3)) (return (g 14))"
             )

    assert message =~ "Undefined variables: defn-, g, x"
    assert message =~ "component source only"
  end

  test "a single name keeps the singular label" do
    assert {"Undefined variable: total", false} =
             PrivateDiagnostic.project(:unbound_var, %{unbound_names: ["total"]}, "(+ total 1)")
  end

  test "drops a name that is not verbatim in the submitted source and says so" do
    assert {message, true} =
             PrivateDiagnostic.project(
               :unbound_var,
               %{unbound_names: ["g", "private-record-key"]},
               "(g 1)"
             )

    # The omission is stated in the message itself, so a consumer that renders
    # only the message cannot read a partial list as the whole cause.
    assert message ==
             "Undefined variable: g (further names withheld by the private result policy)"

    refute message =~ "private-record-key"
  end

  test "redacts entirely when no name survives the source check" do
    assert {@redacted, true} =
             PrivateDiagnostic.project(:unbound_var, %{unbound_names: ["leaked"]}, "(g 1)")
  end

  test "admits a bounded pre-execution message when no capability has run" do
    message = "Analysis error: expected (defn name [params] body)"

    assert {^message, false} =
             PrivateDiagnostic.project(
               :invalid_arity,
               %{message: message, capability_activity?: false},
               "(defn foo)"
             )
  end

  test "pre-execution admission covers the compile and tool-resolution kinds" do
    message = "fixed pre-execution diagnostic"

    for kind <- [
          :parse_error,
          :invalid_arity,
          :invalid_form,
          :symbol_limit_exceeded,
          :compile_timeout,
          :compile_memory_exceeded,
          :unknown_tool,
          :private_tool_unauthorized,
          :unknown_namespace
        ] do
      assert {^message, false} =
               PrivateDiagnostic.project(
                 kind,
                 %{message: message, capability_activity?: false},
                 "(g 1)"
               )
    end
  end

  test "still redacts a pre-execution kind once a capability has run" do
    assert {@redacted, true} =
             PrivateDiagnostic.project(
               :invalid_arity,
               %{
                 message: "expected (defn name [params] body)",
                 capability_activity?: true
               },
               "(defn foo)"
             )
  end

  test "clips an oversized pre-execution message at the admission boundary" do
    message = String.duplicate("a", 5_000)

    assert {admitted, false} =
             PrivateDiagnostic.project(
               :parse_error,
               %{message: message, capability_activity?: false},
               "("
             )

    assert byte_size(admitted) < byte_size(message)
    assert byte_size(admitted) <= 4_096
    assert String.valid?(admitted)
  end

  test "redacts evaluator-produced diagnostics of every other kind" do
    for kind <- [
          :not_callable,
          :type_error,
          :capability_error,
          :memory_exceeded,
          :arity_error,
          nil
        ] do
      assert {@redacted, true} =
               PrivateDiagnostic.project(
                 kind,
                 %{message: "quotes a private record", capability_activity?: false},
                 "(g 1)"
               )
    end
  end

  test "treats malformed or oversized details as no diagnostic at all" do
    source = "(g 1)"

    for details <- [
          %{},
          %{unbound_names: "g"},
          %{unbound_names: [:g]},
          %{unbound_names: [""]},
          %{unbound_names: [<<0xFF>>]},
          %{unbound_names: [String.duplicate("g", 129)]},
          %{unbound_names: ["g" | "improper tail"]},
          %{message: "evaluator text"}
        ] do
      assert {@redacted, true} = PrivateDiagnostic.project(:unbound_var, details, source)
    end
  end

  test "bounds how many names one diagnostic can render" do
    names = for index <- 1..40, do: "n#{index}"
    source = "(" <> Enum.join(names, " ") <> ")"

    assert {message, true} =
             PrivateDiagnostic.project(:unbound_var, %{unbound_names: names}, source)

    assert message =~ "n32"
    refute message =~ "n33"
    assert message =~ "further names withheld"
  end

  test "a non-binary source never produces a message" do
    assert {@redacted, true} =
             PrivateDiagnostic.project(:unbound_var, %{unbound_names: ["g"]}, nil)
  end
end
