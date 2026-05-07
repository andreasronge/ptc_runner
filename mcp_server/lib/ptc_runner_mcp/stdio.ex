defmodule PtcRunnerMcp.Stdio do
  @moduledoc """
  NDJSON stdio reader/writer for the MCP server.

  Per `Plans/ptc-runner-mcp-server.md` § 6.1 / § 6.2:

    * Frames are one UTF-8 JSON-RPC message per line, terminated by
      `\\n`.
    * Stdout carries MCP messages exclusively (no banners, no
      progress).
    * Lines exceeding `max_frame_bytes` are rejected with JSON-RPC
      `-32700` BEFORE JSON parsing; the offending bytes are discarded
      and the reader resyncs at the next newline.
    * stdin EOF triggers a clean exit (§ 6.4).

  The reader is implemented as a `GenServer` that reads from a
  configurable IO device (defaults to `:stdio`) and dispatches each
  decoded line through `PtcRunnerMcp.JsonRpc.dispatch/1`. Replies are
  written via `IO.write/2` to the same device — single-process write
  serialization is sufficient because the GenServer reads one line at
  a time and dispatch happens inline (parallelism is a Phase 2+
  concern).
  """

  use GenServer

  alias PtcRunnerMcp.{JsonRpc, Limits, Log}

  @newline ?\n

  defmodule State do
    @moduledoc false
    defstruct io: :stdio,
              # Bytes accumulated for the in-progress line (no newline yet).
              buffer: <<>>,
              # Once we cross the cap mid-line, drop bytes until next \n.
              dropping: false,
              max_frame_bytes: 8 * 1024 * 1024,
              # When true, ignore further input and exit on EOF.
              draining: false,
              # When true, drop all remaining bytes — set after `exit`
              # notification so any frames buffered behind it are not
              # dispatched (avoids replies after the client said exit).
              exited: false,
              # When true, run the read loop. Tests set this to false
              # and feed bytes directly via Stdio.feed/2.
              auto_read: true,
              # Callback for tests: send a message back to a watcher pid.
              observer: nil
  end

  @doc """
  Start the stdio loop.

  ## Options

    * `:io` — IO device (default `:stdio`). Tests pass an in-memory
      `StringIO` device.
    * `:max_frame_bytes` — overrides the configured limit; defaults
      to `Limits.max_frame_bytes/0`.
    * `:observer` — pid to receive `{__MODULE__, :exited, reason}`
      and `{__MODULE__, :replied, frame}` messages (test only).
    * `:auto_read` — boolean (default `true`). When `false`, the
      reader does not enter its read loop; bytes must be fed via
      `feed/2`. Tests set this to `false`.
    * `:name` — registered name (default `__MODULE__`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    state = %State{
      io: Keyword.get(opts, :io, :stdio),
      max_frame_bytes: Keyword.get(opts, :max_frame_bytes, Limits.max_frame_bytes()),
      observer: Keyword.get(opts, :observer),
      auto_read: Keyword.get(opts, :auto_read, true)
    }

    if state.auto_read, do: send(self(), :read)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:read, %State{io: io} = state) do
    case IO.binread(io, 4096) do
      :eof ->
        Log.log(:info, "stdin_eof")
        notify_observer(state, {:exited, :eof})
        # Phase 1: clean exit on EOF (§ 6.4). System.stop/1 lets the
        # supervisor unwind; tests pass an `:observer` and never reach
        # this branch with the real :stdio device.
        if state.observer == nil do
          System.stop(0)
        end

        {:stop, :normal, state}

      {:error, reason} ->
        Log.log(:error, "stdin_read_error", %{reason: inspect(reason)})
        notify_observer(state, {:exited, {:error, reason}})

        if state.observer == nil do
          System.stop(0)
        end

        {:stop, :normal, state}

      data when is_binary(data) ->
        new_state = process_chunk(state, data)
        send(self(), :read)
        {:noreply, new_state}
    end
  end

  # ----------------------------------------------------------------
  # Public test entry: feed a chunk of bytes and run dispatch inline.
  # ----------------------------------------------------------------

  @doc false
  @spec feed(GenServer.server(), binary()) :: :ok
  def feed(server, bytes) when is_binary(bytes) do
    GenServer.call(server, {:feed, bytes}, 5_000)
  end

  @impl GenServer
  def handle_call({:feed, bytes}, _from, state) do
    {:reply, :ok, process_chunk(state, bytes)}
  end

  # ----------------------------------------------------------------
  # Line accumulation
  # ----------------------------------------------------------------

  defp process_chunk(state, <<>>), do: state

  defp process_chunk(state, data) when is_binary(data) do
    feed_bytes(state, data)
  end

  # Walk the incoming bytes one at a time, using the state's buffer
  # and `:dropping` flag as the only accumulator. We choose
  # byte-at-a-time over `:binary.split/3` because the cap must be
  # enforced BEFORE we ever materialize an oversized line in memory
  # (§ 6.2: "first line of defense against allocation-bomb requests").
  defp feed_bytes(state, <<>>), do: state

  # After an `exit` notification, drop any remaining buffered bytes so
  # we never dispatch (and reply to) a frame that arrived in the same
  # read chunk as `exit`.
  defp feed_bytes(%State{exited: true} = state, _bytes), do: state

  defp feed_bytes(%State{dropping: true} = state, <<@newline, rest::binary>>) do
    # Oversized line ended. Emit one parse-error and resume.
    state = handle_oversized(state)
    feed_bytes(%{state | dropping: false, buffer: <<>>}, rest)
  end

  defp feed_bytes(%State{dropping: true} = state, <<_byte, rest::binary>>) do
    feed_bytes(state, rest)
  end

  defp feed_bytes(%State{dropping: false} = state, <<@newline, rest::binary>>) do
    state = handle_line(state, state.buffer)
    feed_bytes(%{state | buffer: <<>>}, rest)
  end

  defp feed_bytes(
         %State{dropping: false, buffer: buf, max_frame_bytes: cap} = state,
         <<byte, rest::binary>>
       ) do
    new_size = byte_size(buf) + 1

    if new_size > cap do
      # Drop this byte, mark dropping; the next newline triggers the
      # `-32700` and resyncs.
      feed_bytes(%{state | dropping: true, buffer: <<>>}, rest)
    else
      feed_bytes(%{state | buffer: <<buf::binary, byte>>}, rest)
    end
  end

  # ----------------------------------------------------------------
  # Per-line handling
  # ----------------------------------------------------------------

  defp handle_line(state, line) do
    # Strip a trailing \r so CRLF clients work without complaint.
    line =
      case line do
        <<>> ->
          line

        _ ->
          if :binary.last(line) == ?\r, do: :binary.part(line, 0, byte_size(line) - 1), else: line
      end

    decoded =
      case Jason.decode(line) do
        {:ok, value} -> {:ok, value}
        {:error, _} -> {:error, :parse_error}
      end

    case JsonRpc.dispatch(decoded) do
      {:reply, frame, lifecycle} ->
        write_reply(state, frame)
        apply_lifecycle(state, lifecycle)

      {:noreply, lifecycle} ->
        apply_lifecycle(state, lifecycle)
    end
  end

  defp handle_oversized(state) do
    Log.log(:warn, "frame_too_large", %{max_frame_bytes: state.max_frame_bytes})

    write_reply(state, %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "error" => %{"code" => -32_700, "message" => "Parse error"}
    })

    state
  end

  defp write_reply(%State{io: io, observer: observer} = _state, frame) do
    line = Jason.encode!(frame) <> "\n"
    IO.write(io, line)
    if observer, do: send(observer, {__MODULE__, :replied, frame})
    :ok
  end

  defp apply_lifecycle(state, :continue), do: state

  defp apply_lifecycle(state, :drain) do
    %{state | draining: true}
  end

  defp apply_lifecycle(state, :exit) do
    notify_observer(state, {:exited, :exit_method})

    if state.observer == nil do
      System.stop(0)
    end

    %{state | exited: true}
  end

  defp notify_observer(%State{observer: nil}, _), do: :ok

  defp notify_observer(%State{observer: pid}, payload) do
    send(pid, {__MODULE__, payload})
    :ok
  end
end
