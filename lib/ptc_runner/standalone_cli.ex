defmodule PtcRunner.StandaloneCLI do
  @moduledoc false

  alias PtcRunner.Kernel.CommandPresentation
  alias PtcRunner.Kernel.CommandRouter
  alias PtcRunner.ReplFrontend
  alias PtcRunner.StandaloneCommandRuntime

  @doc false
  @spec execute([binary()]) :: CommandPresentation.t()
  def execute(argv),
    do:
      CommandRouter.execute(
        argv,
        :standalone,
        &StandaloneCommandRuntime.bootstrap/1,
        &ReplFrontend.run/2
      )

  @doc false
  @spec main([binary()]) :: no_return()
  def main(argv) do
    presentation = execute(argv)
    if presentation.stdout != "", do: IO.write(:stdio, presentation.stdout)
    if presentation.stderr != "", do: IO.write(:stderr, presentation.stderr)
    System.halt(presentation.exit_status)
  end
end
