defmodule PtcRunner.StandaloneCLI do
  @moduledoc false

  alias PtcRunner.Kernel.CommandPresentation
  alias PtcRunner.Kernel.CommandRouter
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.OneShotFrontend
  alias PtcRunner.StandaloneCommandRuntime

  @doc false
  @spec execute([binary()]) :: CommandPresentation.t()
  def execute(argv), do: execute(argv, [])

  @doc false
  @spec execute([binary()], keyword()) :: CommandPresentation.t()
  def execute(argv, frontend_opts) when is_list(frontend_opts),
    do:
      CommandRouter.execute(
        argv,
        :standalone,
        fn arguments -> bootstrap(arguments, frontend_opts) end,
        fn arguments, runtime ->
          OneShotFrontend.run(
            arguments,
            runtime,
            Keyword.delete(frontend_opts, :live_status)
          )
        end
      )

  defp bootstrap(arguments, frontend_opts) do
    with {:ok, runtime} <- StandaloneCommandRuntime.bootstrap(arguments),
         do: CommandRuntime.attach_live_status(runtime, frontend_opts)
  end

  @doc false
  @spec main([binary()]) :: no_return()
  def main(argv) do
    presentation = execute(argv)
    if presentation.stdout != "", do: IO.write(:stdio, presentation.stdout)
    if presentation.stderr != "", do: IO.write(:stderr, presentation.stderr)
    System.halt(presentation.exit_status)
  end
end
