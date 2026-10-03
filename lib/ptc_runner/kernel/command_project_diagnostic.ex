defmodule PtcRunner.Kernel.CommandProjectDiagnostic do
  @moduledoc false

  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandFailureCause
  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.CommandSource
  alias PtcRunner.Kernel.SchemaViolation
  alias PtcRunner.Kernel.SchemaViolationDiagnostic

  @spec project(
          {:project_unavailable, PtcRunner.Kernel.ConfinedFile.error()}
          | {:project_schema_invalid, SchemaViolation.t()}
          | {:schema_validation_unavailable, SchemaViolation.unavailable_reason()}
        ) :: CommandDiagnostic.t()
  def project({:project_unavailable, reason}) do
    code = if reason == :not_found, do: :application_not_found, else: :application_unavailable
    CommandDiagnostic.new!(:application, code, cause: CommandFailureCause.from_reason(reason))
  end

  def project({:project_schema_invalid, %SchemaViolation{rule: rule, path: segments}}) do
    {:ok, path} = CommandPath.project(segments)
    {:ok, message} = SchemaViolationDiagnostic.message(:project, rule)

    CommandDiagnostic.new!(:project, :project_schema_invalid,
      source: CommandSource.fixed(:project),
      path: path,
      message: message
    )
  end

  def project({:schema_validation_unavailable, cause}) do
    CommandDiagnostic.new!(:project, :schema_validation_unavailable,
      source: CommandSource.fixed(:project),
      cause: CommandFailureCause.from_reason(cause)
    )
  end
end
