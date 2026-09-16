defmodule PtcGateway.ReleaseCLI do
  @moduledoc false

  @spec main([binary()]) :: no_return()
  def main(arguments) do
    reference = install_signal_handler()
    {opts, paths, invalid} = OptionParser.parse(arguments, strict: [env_file: :string])

    case {paths, invalid} do
      {[path], []} -> run(path, opts, reference)
      _ -> fail(:config_invalid)
    end
  end

  @doc false
  def install_signal_handler do
    reference = make_ref()

    if :erl_signal_handler in :gen_event.which_handlers(:erl_signal_server) do
      :ok = :gen_event.delete_handler(:erl_signal_server, :erl_signal_handler, :gateway)
    end

    :ok =
      :gen_event.add_handler(
        :erl_signal_server,
        {PtcGateway.SignalHandler, reference},
        {self(), reference}
      )

    :ok = :os.set_signal(:sigterm, :handle)
    reference
  end

  @doc false
  def await_status(owner, reference) do
    ref = Process.monitor(owner)

    receive do
      {:gateway_signal, ^reference, :sigterm} ->
        if PtcGateway.Domain.shutdown(owner, 10_000, 10_000) == :ok, do: 0, else: 70

      {:DOWN, ^ref, :process, ^owner, :normal} ->
        0

      {:DOWN, ^ref, :process, ^owner, _reason} ->
        70
    end
  end

  defp run(path, opts, reference) do
    case PtcGateway.start_link(path, opts) do
      {:ok, owner} -> wait(owner, reference)
      {:error, code} -> fail(code)
    end
  end

  defp wait(owner, reference) do
    System.halt(await_status(owner, reference))
  end

  defp fail(code) do
    IO.puts(:stderr, PtcGateway.StartupError.encode(code))
    System.halt(PtcGateway.StartupError.exit_status())
  end
end
