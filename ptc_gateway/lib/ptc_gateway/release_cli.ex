defmodule PtcGateway.ReleaseCLI do
  @moduledoc false

  @spec main([binary()]) :: no_return()
  def main(arguments) do
    :ok = :os.set_signal(:sigterm, :handle)
    :ok = :os.set_signal(:sigint, :handle)
    {opts, paths, invalid} = OptionParser.parse(arguments, strict: [env_file: :string])

    case {paths, invalid} do
      {[path], []} -> run(path, opts)
      _ -> fail(:config_invalid)
    end
  end

  defp run(path, opts) do
    case PtcGateway.start_link(path, opts) do
      {:ok, owner} -> wait(owner)
      {:error, code} -> fail(code)
    end
  end

  defp wait(owner) do
    ref = Process.monitor(owner)

    receive do
      {:signal, signal} when signal in [:sigterm, :sigint] ->
        GenServer.stop(owner, :shutdown, 30_000)
        System.halt(0)

      {:DOWN, ^ref, :process, ^owner, :normal} ->
        System.halt(0)

      {:DOWN, ^ref, :process, ^owner, _reason} ->
        System.halt(70)
    end
  end

  defp fail(code) do
    IO.puts(:stderr, PtcGateway.StartupError.encode(code))
    System.halt(PtcGateway.StartupError.exit_status())
  end
end
