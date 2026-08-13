defmodule PtcRunner.Kernel.CompileDiagnosticTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CompileDiagnostic

  test "rebuilds only exact bounded names present in submitted component source" do
    source = "(ns app) (defn run [input] (+ missing-value other-value))"

    assert {:ok, "Undefined variables: missing-value, other-value"} =
             CompileDiagnostic.rebuild(
               :unbound_var,
               %{unbound_names: ["missing-value", "other-value"]},
               source
             )

    assert {:ok, "Duplicate definition: app/run"} =
             CompileDiagnostic.rebuild(
               :duplicate_ref,
               %{duplicate_namespace: "app", duplicate_name: "run"},
               source
             )
  end

  test "rejects malformed, absent, and oversized compiler detail" do
    source = "(ns app) (defn run [] missing-value)"

    invalid = [
      %{},
      %{unbound_names: "missing-value"},
      %{unbound_names: ["not-submitted"]},
      %{unbound_names: [String.duplicate("x", 129)]},
      %{unbound_names: ["missing-value"], extra: "not admitted"},
      %{unbound_names: ["missing-value" | "improper"]},
      %{unbound_names: Enum.map(1..9, &"name#{&1}")}
    ]

    for details <- invalid do
      assert :error = CompileDiagnostic.rebuild(:unbound_var, details, source)
    end

    assert :error =
             CompileDiagnostic.rebuild(
               :duplicate_ref,
               %{duplicate_namespace: "private", duplicate_name: "secret"},
               source
             )
  end

  test "rejects malformed rebuilt messages" do
    refute CompileDiagnostic.valid_message?(
             :duplicate_definition,
             "Duplicate definition: app//run"
           )

    refute CompileDiagnostic.valid_message?(:undefined_variable, "Undefined variables: one")

    refute CompileDiagnostic.valid_message?(
             :undefined_variable,
             "Undefined variables: " <> Enum.map_join(1..9, ", ", &"name#{&1}")
           )

    long_name = String.duplicate("x", 129)
    boundary_name = String.duplicate("x", 128)

    assert CompileDiagnostic.valid_message?(
             :undefined_variable,
             "Undefined variable: #{boundary_name}"
           )

    assert CompileDiagnostic.valid_message?(
             :undefined_variable,
             "Undefined variables: " <> Enum.map_join(1..8, ", ", &"name#{&1}")
           )

    assert CompileDiagnostic.valid_message?(
             :duplicate_definition,
             "Duplicate definition: app/#{boundary_name}"
           )

    refute CompileDiagnostic.valid_message?(
             :undefined_variable,
             "Undefined variable: #{long_name}"
           )

    refute CompileDiagnostic.valid_message?(
             :duplicate_definition,
             "Duplicate definition: app/#{long_name}"
           )
  end

  test "rebuilds only canonical bounded capability requirement messages" do
    assert {:ok, "Missing capability requirement: history.runs"} =
             CompileDiagnostic.capability_requirement_message(["history.runs"])

    assert {:ok, "Missing capability requirements: history.failure, history.runs"} =
             CompileDiagnostic.capability_requirement_message([
               "history.failure",
               "history.runs"
             ])

    for invalid <- [
          [],
          ["history.runs", "history.failure"],
          ["history.runs", "history.runs"],
          Enum.map(1..9, &"history.operation-#{&1}"),
          [String.duplicate("x", 129)]
        ] do
      assert :error = CompileDiagnostic.capability_requirement_message(invalid)
    end

    assert CompileDiagnostic.valid_message?(
             :capability_requirement_missing,
             "Missing capability requirements: history.failure, history.runs"
           )

    refute CompileDiagnostic.valid_message?(
             :capability_requirement_missing,
             "Missing capability requirements: history.runs, history.failure"
           )
  end
end
