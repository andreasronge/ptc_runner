defmodule PtcRunner.Kernel.CommandFrontend do
  @moduledoc false

  alias PtcRunner.Kernel.CommandArguments
  alias PtcRunner.Kernel.CommandDeclaration
  alias PtcRunner.Kernel.CommandDiagnostic
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandEnvelope
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandPresentation
  alias PtcRunner.Kernel.CommandRenderer
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.ProjectArtifactRoot

  @frontend_commands CommandDeclaration.frontend_commands()

  # A publication failure cannot be reported through the envelope it failed to
  # write, so it is the one status that is not a catalog row. `EX_IOERR` says
  # what happened without claiming a diagnostic the reader cannot go read.
  @envelope_failure_exit_status 74

  @doc "The exit status of an envelope that could not be published."
  @spec envelope_failure_exit_status() :: 74
  def envelope_failure_exit_status, do: @envelope_failure_exit_status

  @type bootstrap ::
          (CommandArguments.t() ->
             {:ok, CommandRuntime.t()} | {:error, :command_bootstrap_failed})

  @spec execute([binary()], :standalone | :mix, bootstrap()) :: CommandPresentation.t()
  def execute(argv, frontend, bootstrap)
      when is_list(argv) and frontend in [:standalone, :mix] and is_function(bootstrap, 1) do
    case CommandEntry.open(argv, frontend) do
      {:error, %CommandEntry{} = entry} ->
        present_entry(entry, bootstrap)

      {:ok, %CommandEntry{} = entry} ->
        present_entry(entry, bootstrap)
    end
  end

  @doc false
  @spec present_entry(CommandEntry.t(), bootstrap()) :: CommandPresentation.t()
  def present_entry(
        %CommandEntry{diagnostic: %CommandDiagnostic{} = _diagnostic} = entry,
        _bootstrap
      ) do
    {:error, outcome} = CommandEngine.entry_failure(entry)
    present(entry, outcome, nil)
  end

  def present_entry(%CommandEntry{rejection: %{} = _rejection} = entry, _bootstrap) do
    {:error, outcome} = CommandEngine.entry_failure(entry)
    present(entry, outcome, entry.rejection)
  end

  def present_entry(%CommandEntry{arguments: %{command: command}} = entry, _bootstrap)
      when command in @frontend_commands do
    {:error, outcome} = CommandEngine.dispatch_entry(entry, CommandRuntime.standalone())
    present(entry, outcome, nil)
  end

  def present_entry(%CommandEntry{} = entry, bootstrap) when is_function(bootstrap, 1) do
    {outcome, rejection} = execute_entry(entry, bootstrap)
    present(entry, outcome, rejection)
  end

  defp execute_entry(%CommandEntry{arguments: %{command: command}} = entry, _bootstrap)
       when command in [:help, :version] do
    {_status, outcome, rejection} =
      CommandEngine.dispatch_frontend_entry(entry, CommandRuntime.standalone())

    {outcome, rejection}
  end

  defp execute_entry(%CommandEntry{} = entry, bootstrap) do
    case bootstrap.(entry.arguments) do
      {:ok, %CommandRuntime{} = runtime} ->
        {_status, outcome, rejection} = CommandEngine.dispatch_frontend_entry(entry, runtime)
        {outcome, rejection}

      _failure ->
        {:error, outcome} = CommandEngine.startup_failure(entry)
        {outcome, nil}
    end
  rescue
    _exception ->
      {:error, outcome} = CommandEngine.startup_failure(entry)
      {outcome, nil}
  catch
    _kind, _reason ->
      {:error, outcome} = CommandEngine.startup_failure(entry)
      {outcome, nil}
  end

  defp present(
         %CommandEntry{envelope_path: path} = entry,
         %CommandOutcome{} = outcome,
         rejection
       )
       when is_binary(path) do
    paths = CommandEnvelope.destinations(entry.arguments, path, entry.run_ref)

    result =
      with :ok <- ProjectArtifactRoot.ensure_for(entry.arguments),
           do: CommandEnvelope.publish_all(outcome, paths)

    case result do
      :ok ->
        rendered_presentation(outcome, path, rejection)

      {:error, reason} ->
        presentation(
          outcome,
          nil,
          "",
          CommandRenderer.envelope_failure(entry.run_ref, reason),
          @envelope_failure_exit_status
        )
    end
  end

  defp present(%CommandEntry{}, %CommandOutcome{} = outcome, rejection) do
    rendered_presentation(outcome, nil, rejection)
  end

  defp rendered_presentation(outcome, envelope_path, rejection) do
    case CommandRenderer.render(outcome, rejection) do
      {:stdout, bytes} ->
        presentation(outcome, envelope_path, bytes, "", outcome.exit_status)

      {:stderr, bytes} ->
        presentation(outcome, envelope_path, "", bytes, outcome.exit_status)

      {:stdio, stdout, stderr} ->
        presentation(outcome, envelope_path, stdout, stderr, outcome.exit_status)
    end
  end

  defp presentation(outcome, envelope_path, stdout, stderr, exit_status) do
    %CommandPresentation{
      stdout: stdout,
      stderr: stderr,
      exit_status: exit_status,
      outcome: outcome,
      envelope_path: envelope_path
    }
  end
end
