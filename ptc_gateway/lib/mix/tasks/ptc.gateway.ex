defmodule Mix.Tasks.Ptc.Gateway do
  @shortdoc "Start a loopback gateway from one strict configuration document"
  @moduledoc """
  Run in the sibling gateway project:

      mix ptc.gateway /absolute/path/gateway.json --env-file credentials.env

  The explicit environment file is anchored to the invocation directory.
  Startup failure prints one closed JSON error on stderr and exits 78.
  Success prints nothing and serves until the process is stopped.
  """
  use Mix.Task
  @impl true
  def run(args) do
    {opts, paths, invalid} = OptionParser.parse(args, strict: [env_file: :string])
    Mix.Task.run("app.start")

    result =
      case {paths, invalid} do
        {[path], []} -> PtcGateway.start_link(path, opts)
        _ -> {:error, :config_invalid}
      end

    case result do
      {:ok, owner} ->
        ref = Process.monitor(owner)

        receive do
          {:DOWN, ^ref, :process, ^owner, _} -> :ok
        end

      {:error, code} ->
        IO.puts(:stderr, PtcGateway.StartupError.encode(code))
        System.halt(PtcGateway.StartupError.exit_status())
    end
  end
end
