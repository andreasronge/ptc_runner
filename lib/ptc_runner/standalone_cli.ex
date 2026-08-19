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
    # The dump is Logger reporting the writer's :terminated; removing the
    # default handler after the command has produced its presentation, and
    # before the write, is what keeps stderr empty when the pipe is already
    # closed. MixCommandAdapter cannot do this: it returns to Mix.
    _ = :logger.remove_handler(:default)

    try do
      if presentation.stdout != "", do: IO.write(:stdio, presentation.stdout)
      if presentation.stderr != "", do: IO.write(:stderr, presentation.stderr)
      System.halt(presentation.exit_status)
    rescue
      error in ErlangError ->
        halt_closed_pipe_or_reraise(error, __STACKTRACE__)
    end
  end

  defp halt_closed_pipe_or_reraise(%ErlangError{original: reason}, _stacktrace)
       when reason in [:terminated, :epipe] do
    System.halt(141)
  end

  defp halt_closed_pipe_or_reraise(error, stacktrace), do: reraise(error, stacktrace)
end
