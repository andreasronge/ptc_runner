defmodule PtcRunner.Kernel.CommandRouter do
  @moduledoc false

  alias PtcRunner.CLIProgress
  alias PtcRunner.Dotenv
  alias PtcRunner.Kernel.CommandDeclaration
  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandFrontend
  alias PtcRunner.Kernel.CommandPresentation
  alias PtcRunner.Kernel.CommandRenderer
  alias PtcRunner.Kernel.CommandRuntime

  @frontend_commands CommandDeclaration.frontend_commands()

  @type bootstrap :: CommandFrontend.bootstrap()
  @type one_shot_runner :: (PtcRunner.Kernel.CommandArguments.t(), CommandRuntime.t() ->
                              :ok | {:error, binary()} | {:error, atom(), binary()})

  @spec execute([binary()], :standalone | :mix, bootstrap(), one_shot_runner(), keyword()) ::
          CommandPresentation.t()
  def execute(argv, frontend, bootstrap, repl_runner, frontend_opts \\ [])
      when is_list(argv) and frontend in [:standalone, :mix] and is_function(bootstrap, 1) and
             is_function(repl_runner, 2) and is_list(frontend_opts) do
    case CommandEntry.open(argv, frontend) do
      {:error, %CommandEntry{rejection: %{command: command}} = entry}
      when command in @frontend_commands ->
        presentation(nil, "", CommandRenderer.rejection(entry.run_ref, entry.rejection), 2)

      {:error, %CommandEntry{} = entry} ->
        CommandFrontend.present_entry(entry, bootstrap)

      {:ok, %CommandEntry{arguments: %{command: command}} = entry}
      when command in @frontend_commands ->
        run_one_shot(entry, bootstrap, repl_runner)

      {:ok, %CommandEntry{arguments: %{command: :run} = arguments} = entry} ->
        with_progress(arguments, frontend_opts, fn progress ->
          present_run(entry, bootstrap, progress)
        end)

      {:ok, %CommandEntry{} = entry} ->
        CommandFrontend.present_entry(entry, bootstrap)
    end
  end

  defp present_run(entry, bootstrap, progress) do
    presentation =
      CommandFrontend.present_entry(entry, fn parsed ->
        with {:ok, runtime} <- bootstrap.(parsed),
             do: CLIProgress.attach(runtime, progress)
      end)

    CLIProgress.finish(progress, presentation)
    presentation
  end

  defp with_progress(arguments, frontend_opts, fun) do
    if Keyword.get(arguments.frontend_options, :progress, false) do
      progress = CLIProgress.start(arguments, frontend_opts)
      fun.(progress)
    else
      fun.(nil)
    end
  end

  defp run_one_shot(entry, bootstrap, runner) do
    env_file = Keyword.get(entry.arguments.frontend_options, :env_file)

    Dotenv.with_file_scope(env_file, fn ->
      run_one_shot_scoped(entry, bootstrap, runner)
    end)
  rescue
    _exception ->
      internal_error(entry)
  catch
    _kind, _reason ->
      internal_error(entry)
  end

  defp run_one_shot_scoped(entry, bootstrap, runner) do
    case bootstrap.(entry.arguments) do
      {:ok, %CommandRuntime{} = runtime} ->
        case runner.(entry.arguments, runtime) do
          :ok ->
            presentation(nil, "", "", 0)

          {:error, code, message} ->
            presentation(
              nil,
              "",
              one_shot_error(entry.arguments.command, code, message, entry.run_ref),
              1
            )

          {:error, message} ->
            presentation(
              nil,
              "",
              one_shot_error(entry.arguments.command, :command_failed, message, entry.run_ref),
              1
            )
        end

      _failure ->
        presentation(
          nil,
          "",
          one_shot_error(
            entry.arguments.command,
            :startup_failed,
            "the #{entry.arguments.command} command could not be started",
            entry.run_ref
          ),
          70
        )
    end
  end

  defp internal_error(entry),
    do:
      presentation(
        nil,
        "",
        one_shot_error(
          entry.arguments.command,
          :internal_error,
          "the #{entry.arguments.command} command failed internally",
          entry.run_ref
        ),
        70
      )

  defp one_shot_error(command, code, message, run_ref) do
    safe =
      if is_binary(message) and String.valid?(message),
        do: message |> String.replace(~r/[\x00-\x1F\x7F]/u, " ") |> String.slice(0, 512),
        else: "#{command} command failed"

    "error: #{command}/#{code}: #{safe} (run_ref: #{run_ref})\n"
  end

  defp presentation(outcome, stdout, stderr, exit_status) do
    %CommandPresentation{
      stdout: stdout,
      stderr: stderr,
      exit_status: exit_status,
      outcome: outcome,
      envelope_path: nil
    }
  end
end
