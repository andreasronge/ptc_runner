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
  alias PtcRunner.Kernel.ProjectConfig
  alias PtcRunner.Kernel.ProjectContext

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
    {outcome, rejection, named_env_file?} = execute_entry(entry, bootstrap)
    present(entry, outcome, rejection, named_env_file?)
  end

  @doc false
  @spec present_outcome(CommandEntry.t(), CommandOutcome.t()) :: CommandPresentation.t()
  def present_outcome(%CommandEntry{} = entry, %CommandOutcome{} = outcome),
    do: present(entry, outcome, nil)

  defp execute_entry(%CommandEntry{arguments: %{command: command}} = entry, _bootstrap)
       when command in [:help, :version] do
    {_status, outcome, rejection, named_env_file?} =
      CommandEngine.dispatch_frontend_entry_with_context(entry, CommandRuntime.standalone())

    {outcome, rejection, named_env_file?}
  end

  defp execute_entry(%CommandEntry{} = entry, bootstrap) do
    case bootstrap.(entry.arguments) do
      {:ok, %CommandRuntime{} = runtime} ->
        {_status, outcome, rejection, named_env_file?} =
          CommandEngine.dispatch_frontend_entry_with_context(entry, runtime)

        {outcome, rejection, named_env_file?}

      _failure ->
        {:error, outcome} = CommandEngine.startup_failure(entry)
        {outcome, nil, false}
    end
  rescue
    _exception ->
      {:error, outcome} = CommandEngine.startup_failure(entry)
      {outcome, nil, false}
  catch
    _kind, _reason ->
      {:error, outcome} = CommandEngine.startup_failure(entry)
      {outcome, nil, false}
  end

  defp present(
         entry,
         outcome,
         rejection
       ),
       do: present(entry, outcome, rejection, false)

  defp present(
         %CommandEntry{envelope_path: path} = entry,
         %CommandOutcome{} = outcome,
         rejection,
         named_env_file?
       )
       when is_binary(path) do
    paths = CommandEnvelope.destinations(entry.arguments, path, entry.run_ref)

    result =
      with :ok <- ProjectArtifactRoot.ensure_for(entry.arguments),
           do: CommandEnvelope.publish_all(outcome, paths)

    case result do
      :ok ->
        rendered_presentation(entry, outcome, path, rejection, named_env_file?)

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

  defp present(%CommandEntry{} = entry, %CommandOutcome{} = outcome, rejection, named_env_file?) do
    rendered_presentation(entry, outcome, nil, rejection, named_env_file?)
  end

  defp rendered_presentation(entry, outcome, envelope_path, rejection, named_env_file?) do
    render_options = [
      named_env_file: named_env_file?,
      application_path: terminal_application_path(entry.arguments)
    ]

    case CommandRenderer.render(outcome, rejection, render_options) do
      {:stdout, bytes} ->
        presentation(outcome, envelope_path, bytes, "", outcome.exit_status)

      {:stderr, bytes} ->
        presentation(outcome, envelope_path, "", bytes, outcome.exit_status)

      {:stdio, stdout, stderr} ->
        presentation(outcome, envelope_path, stdout, stderr, outcome.exit_status)
    end
  end

  defp terminal_application_path(%CommandArguments{
         project: %ProjectContext{
           config: %ProjectConfig{application: application, directory: directory}
         }
       }),
       do: Path.relative_to(application, directory)

  defp terminal_application_path(%CommandArguments{application: application}),
    do: application

  defp terminal_application_path(_arguments), do: nil

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
