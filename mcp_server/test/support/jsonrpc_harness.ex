defmodule PtcRunnerMcp.Test.JsonRpcHarness do
  @moduledoc """
  Test harness for `PtcRunnerMcp.Stdio`.

  Spins up a `Stdio` GenServer with `auto_read: false`, an in-memory
  `StringIO` device, and the test process as the observer. Bytes are
  fed synchronously via `feed_bytes/2`; replies are read out of the
  StringIO buffer after each call.
  """

  alias PtcRunnerMcp.Stdio

  @doc "Start the harness. Returns `{:ok, %{stdio: pid, io: pid}}`."
  @spec start(keyword()) :: {:ok, %{stdio: pid(), io: pid()}}
  def start(opts \\ []) do
    {:ok, io} = StringIO.open(<<>>, capture_prompt: false)
    name = :"stdio_#{System.unique_integer([:positive])}"

    {:ok, stdio} =
      Stdio.start_link(
        Keyword.merge(
          [io: io, observer: self(), auto_read: false, name: name],
          opts
        )
      )

    {:ok, %{stdio: stdio, io: io}}
  end

  @doc "Stop the harness."
  @spec stop(map()) :: :ok
  def stop(%{stdio: stdio, io: io}) do
    if Process.alive?(stdio), do: GenServer.stop(stdio, :normal, 1_000)
    if Process.alive?(io), do: StringIO.close(io)
    :ok
  end

  @doc """
  Encode a JSON-RPC request map (or pass-through binary), feed it to
  the stdio loop, and return the list of decoded reply frames written
  during dispatch.
  """
  @spec roundtrip(map() | binary(), map()) :: [map()]
  def roundtrip(input, %{stdio: stdio, io: io}) do
    bytes =
      case input do
        m when is_map(m) -> Jason.encode!(m) <> "\n"
        b when is_binary(b) -> b
      end

    # Drop anything left in the output buffer so we only see this
    # round-trip's replies.
    _ = StringIO.flush(io)

    :ok = Stdio.feed(stdio, bytes)

    io
    |> StringIO.flush()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
