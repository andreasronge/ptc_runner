defmodule PtcRunner.Kernel.CommandRouter do
  @moduledoc false

  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandFrontend
  alias PtcRunner.Kernel.CommandPresentation
  alias PtcRunner.Kernel.CommandRenderer
  alias PtcRunner.Kernel.CommandRuntime

  @type bootstrap :: CommandFrontend.bootstrap()
  @type repl_runner :: (PtcRunner.Kernel.CommandArguments.t(), CommandRuntime.t() ->
                          :ok | {:error, binary()})

  @spec execute([binary()], :standalone | :mix, bootstrap(), repl_runner()) ::
          CommandPresentation.t()
  def execute(argv, frontend, bootstrap, repl_runner)
      when is_list(argv) and frontend in [:standalone, :mix] and is_function(bootstrap, 1) and
             is_function(repl_runner, 2) do
    case CommandEntry.open(argv, frontend) do
      {:error, %CommandEntry{rejection: %{command: :repl}} = entry} ->
        presentation(nil, "", CommandRenderer.rejection(entry.run_ref, entry.rejection), 2)

      {:error, %CommandEntry{} = entry} ->
        CommandFrontend.present_entry(entry, bootstrap)

      {:ok, %CommandEntry{arguments: %{command: :repl}} = entry} ->
        run_repl(entry, bootstrap, repl_runner)

      {:ok, %CommandEntry{} = entry} ->
        CommandFrontend.present_entry(entry, bootstrap)
    end
  end

  defp run_repl(entry, bootstrap, repl_runner) do
    case bootstrap.(entry.arguments) do
      {:ok, %CommandRuntime{} = runtime} ->
        case repl_runner.(entry.arguments, runtime) do
          :ok -> presentation(nil, "", "", 0)
          {:error, message} -> presentation(nil, "", repl_error(message, entry.run_ref), 1)
        end

      _failure ->
        presentation(
          nil,
          "",
          "error: repl/startup_failed: the repl could not be started " <>
            "(run_ref: #{entry.run_ref})\n",
          70
        )
    end
  rescue
    _exception ->
      presentation(
        nil,
        "",
        "error: repl/internal_error: the repl failed internally " <>
          "(run_ref: #{entry.run_ref})\n",
        70
      )
  catch
    _kind, _reason ->
      presentation(
        nil,
        "",
        "error: repl/internal_error: the repl failed internally " <>
          "(run_ref: #{entry.run_ref})\n",
        70
      )
  end

  defp repl_error(message, run_ref) do
    safe =
      if is_binary(message) and String.valid?(message),
        do: message |> String.replace(~r/[\x00-\x1F\x7F]/u, " ") |> String.slice(0, 512),
        else: "repl command failed"

    "error: repl/command_failed: #{safe} (run_ref: #{run_ref})\n"
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
