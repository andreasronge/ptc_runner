defmodule PtcRunner.Kernel.CompileDiagnosticTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandContract
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.CompileDiagnostic
  alias PtcRunner.Lisp.NamespaceDiagnostic

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

    assert {:ok, message} =
             CompileDiagnostic.rebuild(
               :unknown_namespace,
               NamespaceDiagnostic.details("kernel"),
               "(ns app) (defn run [] (kernel/eval-source \"42\"))"
             )

    assert message == NamespaceDiagnostic.message("kernel")
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

    assert :error =
             CompileDiagnostic.rebuild(
               :unknown_namespace,
               NamespaceDiagnostic.details("kernel"),
               source
             )

    assert :error =
             CompileDiagnostic.rebuild(
               :unknown_namespace,
               %{
                 rejected_namespace: "missing-value",
                 available_namespaces: ["private/"]
               },
               source
             )
  end

  test "rejects malformed rebuilt messages" do
    refute CompileDiagnostic.valid_message?(
             :duplicate_definition,
             "Duplicate definition: app//run"
           )

    assert CompileDiagnostic.valid_message?(
             :unknown_namespace,
             NamespaceDiagnostic.message("kernel")
           )

    refute CompileDiagnostic.valid_message?(
             :unknown_namespace,
             NamespaceDiagnostic.message("kernel") <> " private"
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

  test "canonical unknown-namespace messages stay within the command contract" do
    namespace = String.duplicate("n", 128)
    source = "(ns app) (defn run [] (#{namespace}/missing))"

    assert {:ok, message} =
             CompileDiagnostic.rebuild(
               :unknown_namespace,
               NamespaceDiagnostic.details(namespace),
               source
             )

    assert CompileDiagnostic.valid_message?(:unknown_namespace, message)

    component = CommandSource.with_bytes(:component, "main.clj", source)

    assert {:ok, diagnostic} =
             CommandDiagnostic.new(:bundle, :unknown_namespace,
               message: message,
               source: component
             )

    assert {:ok, schema} =
             CommandContract.catalog_diagnostic_schema()
             |> JSV.build(atoms: false, warnings: :silent)

    assert {:ok, _validated} =
             diagnostic
             |> CommandDiagnostic.to_map()
             |> JSV.validate(schema, cast: false)
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
