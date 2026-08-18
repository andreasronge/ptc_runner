defmodule PtcRunner.MixCommandAdapter do
  @moduledoc false

  alias PtcRunner.Kernel.CommandPresentation
  alias PtcRunner.Kernel.CommandRouter
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.MixCommandRuntime
  alias PtcRunner.OneShotFrontend

  @doc false
  @spec execute([binary()]) :: CommandPresentation.t()
  def execute(args), do: execute(args, [])

  @doc false
  @spec execute([binary()], keyword()) :: CommandPresentation.t()
  def execute(args, frontend_opts) when is_list(args) and is_list(frontend_opts),
    do:
      CommandRouter.execute(
        args,
        :mix,
        fn arguments -> bootstrap(arguments, frontend_opts) end,
        fn arguments, runtime ->
          OneShotFrontend.run(arguments, runtime, repl_frontend_opts(frontend_opts))
        end
      )

  def execute(_args, _frontend_opts), do: execute([], [])

  defp bootstrap(arguments, frontend_opts) do
    with {:ok, runtime} <- MixCommandRuntime.bootstrap(arguments),
         do: CommandRuntime.attach_live_status(runtime, frontend_opts)
  end

  defp repl_frontend_opts(opts), do: Keyword.delete(opts, :live_status)

  @doc false
  @spec run_task([binary()]) :: CommandPresentation.t() | no_return()
  def run_task(args), do: run_task(args, [])

  @doc false
  @spec run_task([binary()], keyword()) :: CommandPresentation.t() | no_return()
  def run_task(args, frontend_opts) when is_list(args) and is_list(frontend_opts) do
    presentation = execute(args, frontend_opts)

    case presentation do
      %CommandPresentation{exit_status: 0} ->
        write_output(presentation.stdout, presentation.stderr)
        presentation

      %CommandPresentation{exit_status: status, stdout: stdout, stderr: ""}
      when stdout != "" ->
        write_output(stdout, "")
        exit({:shutdown, status})

      %CommandPresentation{exit_status: status} ->
        Mix.raise(failure_message(presentation), exit_status: status)
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
