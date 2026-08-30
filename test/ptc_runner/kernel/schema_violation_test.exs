defmodule PtcRunner.Kernel.SchemaViolationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandApplicationDiagnostic
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandProjectDiagnostic
  alias PtcRunner.Kernel.DiagnosticCatalog
  alias PtcRunner.Kernel.SchemaViolation

  test "a bounded-worker failure is unavailable rather than a schema violation" do
    schema = %{"allOf" => List.duplicate(%{"type" => "object"}, 20_000)}

    assert {:unavailable, reason} = SchemaViolation.validate(%{}, schema)
    assert reason in [:timeout, :heap_exceeded, :worker_failed]
  end

  test "command diagnostics keep unavailable schema validation retryable and value-free" do
    project = CommandProjectDiagnostic.project({:schema_validation_unavailable, :timeout})

    application =
      CommandApplicationDiagnostic.project(
        :validate,
        {:schema_validation_unavailable, :heap_exceeded}
      )

    assert %CommandDiagnostic{
             phase: :project,
             code: :schema_validation_unavailable,
             path: nil,
             retryable: true
           } = project

    assert %CommandDiagnostic{
             phase: :application,
             code: :schema_validation_unavailable,
             path: nil,
             retryable: true
           } = application

    assert %{retryable: true} =
             DiagnosticCatalog.fetch!(:host, :schema_validation_unavailable)
  end

  test "oneOf with successful branches ignores invalidated branch metadata" do
    invalid_branch = %{
      kind: :type,
      data_path: [{:property, "value"}],
      args: [expected: :integer]
    }

    error = %{
      kind: :oneOf,
      data_path: [],
      args: [
        validated: [{0, %{}, %{}}, {1, %{}, %{}}],
        invalidated: [{2, %{errors: [invalid_branch]}}]
      ]
    }

    assert %SchemaViolation{rule: :one_of, path: []} =
             SchemaViolation.from_jsv([error], %{
               "oneOf" => [
                 %{"type" => "object"},
                 %{"type" => "object"},
                 %{"type" => "object", "properties" => %{"value" => %{"type" => "integer"}}}
               ]
             })
  end
end
