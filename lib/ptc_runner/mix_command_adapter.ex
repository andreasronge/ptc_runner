defmodule PtcRunner.MixCommandAdapter do
  @moduledoc false

  alias PtcRunner.Kernel.CommandPresentation
  alias PtcRunner.Kernel.CommandRouter
  alias PtcRunner.MixCommandRuntime
  alias PtcRunner.ReplFrontend

  @doc false
  @spec execute([binary()]) :: CommandPresentation.t()
  def execute(args) when is_list(args),
    do:
      CommandRouter.execute(
        args,
        :mix,
        &MixCommandRuntime.bootstrap/1,
        &ReplFrontend.run/2
      )

  def execute(_args), do: execute([])

  @doc false
  @spec run_task([binary()], :exit | :raise) :: CommandPresentation.t() | no_return()
  def run_task(args, failure_mode) when is_list(args) and failure_mode in [:exit, :raise] do
    presentation = execute(args)

    case {presentation.exit_status, failure_mode} do
      {0, _mode} ->
        write_output(presentation.stdout, presentation.stderr)
        presentation

      {_status, :exit} ->
        write_output(presentation.stdout, presentation.stderr)
        exit({:shutdown, presentation.exit_status})

      {_status, :raise} ->
        Mix.raise(failure_message(presentation))
    end
  end

  defp failure_message(%CommandPresentation{stderr: "", exit_status: status}),
    do: "ptc command failed with status #{status}"

  defp failure_message(%CommandPresentation{stderr: stderr}),
    do: String.trim_trailing(stderr, "\n")

  defp write_output(stdout, stderr) do
    if stdout != "", do: IO.write(stdout)
    if stderr != "", do: IO.write(:stderr, stderr)
  end
end
