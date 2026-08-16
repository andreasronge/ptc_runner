defmodule PtcRunner.StandaloneCLI do
  @moduledoc false

  alias PtcRunner.Kernel.CommandPresentation
  alias PtcRunner.Kernel.CommandRouter
  alias PtcRunner.ReplFrontend
  alias PtcRunner.StandaloneCommandRuntime
  alias PtcRunner.TranscriptFrontend
  alias PtcRunner.ViewerFrontend

  @doc false
  @spec execute([binary()]) :: CommandPresentation.t()
  def execute(argv),
    do:
      CommandRouter.execute(
        argv,
        :standalone,
        &StandaloneCommandRuntime.bootstrap/1,
        &run_one_shot/2
      )

  defp run_one_shot(%{command: :repl} = arguments, runtime),
    do: ReplFrontend.run(arguments, runtime)

  defp run_one_shot(%{command: :transcript} = arguments, runtime),
    do: TranscriptFrontend.run(arguments, runtime)

  defp run_one_shot(%{command: :viewer} = arguments, runtime),
    do: ViewerFrontend.run(arguments, runtime)

  @doc false
  @spec main([binary()]) :: no_return()
  def main(argv) do
    presentation = execute(argv)
    if presentation.stdout != "", do: IO.write(:stdio, presentation.stdout)
    if presentation.stderr != "", do: IO.write(:stderr, presentation.stderr)
    System.halt(presentation.exit_status)
  end
end
