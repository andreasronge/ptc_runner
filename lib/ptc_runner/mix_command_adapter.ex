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
  @spec run_task([binary()]) :: CommandPresentation.t() | no_return()
  def run_task(args) when is_list(args) do
    presentation = execute(args)

    case presentation.exit_status do
      0 ->
        write_output(presentation.stdout, presentation.stderr)
        presentation

      status ->
        Mix.raise(failure_message(presentation), exit_status: status)
    end
  end

  defp failure_message(%CommandPresentation{stdout: stdout, stderr: ""}) when stdout != "",
    do: String.trim_trailing(stdout, "\n")

  defp failure_message(%CommandPresentation{stderr: "", exit_status: status}),
    do: "ptc command failed with status #{status}"

  defp failure_message(%CommandPresentation{stderr: stderr}),
    do: String.trim_trailing(stderr, "\n")

  defp write_output(stdout, stderr) do
    if stdout != "", do: IO.write(stdout)
    if stderr != "", do: IO.write(:stderr, stderr)
  end
end
