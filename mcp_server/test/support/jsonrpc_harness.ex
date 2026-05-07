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
    safe_stop(stdio, fn -> GenServer.stop(stdio, :normal, 1_000) end)
    safe_stop(io, fn -> StringIO.close(io) end)
    :ok
  end

  defp safe_stop(pid, fun) do
    if Process.alive?(pid) do
      try do
        fun.()
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @doc """
  Encode a JSON-RPC request map (or pass-through binary), feed it to
  the stdio loop, and return the list of decoded reply frames written
  during dispatch.

  Phase 4: `tools/call` runs in a per-call worker, so the reply is
  written *after* `Stdio.feed/2` returns. Drain pending observer
  `{Stdio, :replied, frame}` messages with a short timeout so we
  capture async replies, then read whatever the StringIO buffer has.
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
    _ = drain_replied_messages()

    :ok = Stdio.feed(stdio, bytes)

    # Wait for at least one async reply (or no-reply timeout) — we use
    # the observer's `:replied` notification to know when an async
    # worker's envelope has been written. Synchronous replies (for
    # `initialize`, `tools/list`, etc.) are also notified, so this is
    # uniform for all paths.
    _ = wait_for_reply(150)

    io
    |> StringIO.flush()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  @doc """
  Wait up to `timeout_ms` for a `{Stdio, :replied, frame}` observer
  message. Returns `:ok` if one arrived, `:timeout` otherwise. Used
  to synchronize on async tools/call replies before reading StringIO.
  """
  @spec wait_for_reply(non_neg_integer()) :: :ok | :timeout
  def wait_for_reply(timeout_ms) do
    receive do
      {Stdio, :replied, _frame} -> :ok
    after
      timeout_ms -> :timeout
    end
  end

  @doc "Drain any `{Stdio, :replied, ...}` messages left in the mailbox."
  @spec drain_replied_messages() :: :ok
  def drain_replied_messages do
    receive do
      {Stdio, :replied, _} -> drain_replied_messages()
    after
      0 -> :ok
    end
  end
end
