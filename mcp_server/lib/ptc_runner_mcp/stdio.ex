defmodule PtcRunnerMcp.Stdio do
  @moduledoc """
  NDJSON stdio reader/writer for the MCP server.

  Per `Plans/ptc-runner-mcp-server.md` § 6.1 / § 6.2 / § 6.3 / § 6.4:

    * Frames are one UTF-8 JSON-RPC message per line, terminated by
      `\\n`.
    * Stdout carries MCP messages exclusively (no banners, no
      progress).
    * Lines exceeding `max_frame_bytes` are rejected with JSON-RPC
      `-32700` BEFORE JSON parsing; the offending bytes are discarded
      and the reader resyncs at the next newline.
    * stdin EOF triggers a clean exit (§ 6.4) — all in-flight workers
      are killed, no further responses emitted.
    * `tools/call name: "ptc_lisp_execute"` runs in a per-call worker
      process spawned by this GenServer (§ 6.3, § 11). Workers are
      monitored; the in-flight permit is acquired by stdio before
      spawn and released on `:DOWN`. `notifications/cancelled` looks
      up the worker pid and kills it (§ 6.4 row 3).
    * `shutdown` transitions to `:drain`: in-flight workers complete,
      new `tools/call` requests are rejected with the MCP-only
      `shutting_down` envelope (NOT a JSON-RPC `-32600`, NOT a shared
      `error_reason` — see `Envelope.shutting_down/0`). On the
      subsequent `exit` notification, stdio waits up to a small grace
      period for in-flight workers, then exits 0.
  """

  use GenServer

  alias PtcRunnerMcp.{ConcurrencyGate, Envelope, JsonRpc, Limits, Log}

  @newline ?\n

  # Grace period (ms) we give in-flight workers after `exit` before
  # killing them and stopping. Short enough that a stuck program
  # cannot hang the process; long enough that a near-completing
  # program finishes cleanly.
  @exit_grace_ms 2_000

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            io: term(),
            buffer: binary(),
            dropping: boolean(),
            max_frame_bytes: pos_integer(),
            draining: boolean(),
            exited: boolean(),
            auto_read: boolean(),
            observer: pid() | nil,
            in_flight: %{optional(term()) => %{pid: pid(), ref: reference()}},
            workers: %{optional(pid()) => term()},
            exit_pending: boolean()
          }

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
              observer: nil,
              # Per-call workers in flight. `%{request_id => %{pid:, ref:}}`.
              # Stdio holds the concurrency permit on each entry's behalf;
              # `release` happens on :DOWN regardless of exit reason so a
              # `Process.exit(pid, :kill)` from `notifications/cancelled`
              # cannot leak a permit (Phase 4 design).
              in_flight: %{},
              # Reverse index: `%{worker_pid => request_id}` for fast
              # `:DOWN` lookup.
              workers: %{},
              # Set after `exit` notification arrives; once `in_flight`
              # is empty (or grace period elapses) we stop.
              exit_pending: false
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
    # We monitor workers and need to handle their `:DOWN` messages,
    # but we do NOT trap exits — workers are spawned via
    # `spawn_monitor` (no link) so a worker crash cannot take stdio
    # down (and per-worker links to the sandbox child stay confined
    # to the worker).
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
        # § 6.4 row 1: cancel all in-flight workers, no further replies.
        state = cancel_all_workers(state, :stdin_eof)
        notify_observer(state, {:exited, :eof})

        if state.observer == nil do
          System.stop(0)
        end

        {:stop, :normal, state}

      {:error, reason} ->
        Log.log(:error, "stdin_read_error", %{reason: inspect(reason)})
        state = cancel_all_workers(state, {:read_error, reason})
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

  # Worker reply: write the success_reply, demonitor, release permit,
  # remove from in-flight tables.
  @impl GenServer
  def handle_info({:async_reply, request_id, envelope}, state) do
    case Map.fetch(state.in_flight, request_id) do
      {:ok, %{ref: ref}} ->
        Log.log(:info, "tools_call_stop", %{
          request_id: request_id,
          is_error: Map.get(envelope, "isError")
        })

        write_reply(state, success_reply(request_id, envelope))
        Process.demonitor(ref, [:flush])

        state = remove_in_flight(state, request_id)

        {:noreply, maybe_finalize_exit(state)}

      :error ->
        # Late reply (shouldn't happen — we demonitor synchronously
        # on cancel — but guard against races). Just drop.
        Log.log(:warn, "async_reply_unknown", %{request_id: request_id})
        {:noreply, state}
    end
  end

  # Worker DOWN: the worker process exited. Either:
  #   * we already removed it via :async_reply (impossible — we
  #     demonitor with :flush on that path) — covered by `:error` arm.
  #   * the worker crashed (release permit, optionally reply with
  #     internal error if it never sent {:async_reply}).
  #   * the worker was killed via `notifications/cancelled` (release
  #     permit, NO reply per § 6.4 row 3).
  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.fetch(state.workers, pid) do
      {:ok, request_id} ->
        Log.log(:debug, "worker_down", %{
          request_id: request_id,
          reason: inspect(reason)
        })

        case reason do
          :killed ->
            # Cancellation path (or stdin EOF / drain kill): no reply.
            :ok

          :normal ->
            # Worker exited normally without sending :async_reply —
            # shouldn't happen under our protocol; leave audit log.
            :ok

          _other ->
            # Genuine crash. Surface as -32603 so the client knows
            # the call failed (§ 6.4 row 5). Notifications would have
            # `id == nil`, but tools/call always carries one.
            write_reply(state, error_reply(request_id, -32_603, "Internal error"))
        end

        state = remove_in_flight(state, request_id)
        {:noreply, maybe_finalize_exit(state)}

      :error ->
        # Stale DOWN (already cleaned up via :async_reply path) or a
        # process we didn't spawn. Ignore.
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:exit_grace_elapsed, ref}, %State{exit_pending: true} = state)
      when is_reference(ref) do
    # The grace period for in-flight workers after `exit` has elapsed.
    # Force-kill any remaining workers (their permits will be released
    # on :DOWN), then stop.
    Log.log(:warn, "exit_grace_elapsed", %{remaining: map_size(state.in_flight)})
    state = cancel_all_workers(state, :exit_grace_elapsed)

    if state.observer == nil do
      System.stop(0)
    end

    notify_observer(state, {:exited, :exit_method})
    {:stop, :normal, %{state | exited: true}}
  end

  def handle_info({:exit_grace_elapsed, _ref}, state), do: {:noreply, state}

  # ----------------------------------------------------------------
  # Public test entry: feed a chunk of bytes and run dispatch inline.
  # ----------------------------------------------------------------

  @doc false
  @spec feed(GenServer.server(), binary()) :: :ok
  def feed(server, bytes) when is_binary(bytes) do
    GenServer.call(server, {:feed, bytes}, 5_000)
  end

  @doc false
  @spec in_flight_count(GenServer.server()) :: non_neg_integer()
  def in_flight_count(server) do
    GenServer.call(server, :in_flight_count, 5_000)
  end

  @impl GenServer
  def handle_call({:feed, bytes}, _from, state) do
    {:reply, :ok, process_chunk(state, bytes)}
  end

  def handle_call(:in_flight_count, _from, state) do
    {:reply, map_size(state.in_flight), state}
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

    case JsonRpc.dispatch(decoded, draining: state.draining) do
      {:reply, frame, lifecycle} ->
        write_reply(state, frame)
        apply_lifecycle(state, lifecycle)

      {:noreply, lifecycle} ->
        apply_lifecycle(state, lifecycle)

      {:async_call, request_id, work_fn, lifecycle} ->
        state
        |> apply_lifecycle(lifecycle)
        |> handle_async_call(request_id, work_fn)

      {:cancel, request_id, lifecycle} ->
        state
        |> apply_lifecycle(lifecycle)
        |> cancel_request(request_id)
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
    Log.log(:debug, "exit_notification", %{in_flight: map_size(state.in_flight)})

    cond do
      state.exited ->
        # Already exited (idempotent).
        state

      map_size(state.in_flight) == 0 ->
        # No work to drain — exit immediately.
        notify_observer(state, {:exited, :exit_method})

        if state.observer == nil do
          System.stop(0)
        end

        %{state | exited: true}

      true ->
        # Workers still running — schedule grace-period kill, but DON'T
        # `System.stop` yet. `:async_reply`/`:DOWN` handlers will check
        # `exit_pending` and finalize once `in_flight` empties.
        ref = make_ref()
        Process.send_after(self(), {:exit_grace_elapsed, ref}, @exit_grace_ms)
        %{state | exit_pending: true}
    end
  end

  defp notify_observer(%State{observer: nil}, _), do: :ok

  defp notify_observer(%State{observer: pid}, payload) do
    send(pid, {__MODULE__, payload})
    :ok
  end

  # ----------------------------------------------------------------
  # Async call worker management (Phase 4)
  # ----------------------------------------------------------------

  # Acquire a permit and spawn a worker. Permit ownership stays with
  # stdio: it is released on `:async_reply` (normal completion) or on
  # `:DOWN` (cancellation / crash), so a worker `Process.exit(:kill)`
  # cannot leak a permit via a skipped `try/after` — see § 6.3 / § 11.
  #
  # Returns updated state.
  @doc false
  @spec handle_async_call(State.t(), term(), (-> map())) :: State.t()
  def handle_async_call(%State{} = state, request_id, work_fn)
      when is_function(work_fn, 0) do
    cap = Limits.max_concurrent_calls()

    case ConcurrencyGate.try_acquire(cap) do
      :ok ->
        spawn_worker(state, request_id, work_fn)

      :full ->
        # Cap reached — emit `busy` synchronously, no worker spawned.
        envelope = Envelope.busy(cap)

        Log.log(:info, "tools_call_stop", %{
          request_id: request_id,
          is_error: true,
          reason: "busy"
        })

        write_reply(state, success_reply(request_id, envelope))
        state
    end
  end

  defp spawn_worker(state, request_id, work_fn) do
    parent = self()

    {worker_pid, ref} =
      spawn_monitor(fn ->
        envelope =
          try do
            work_fn.()
          rescue
            error ->
              # Work function raised — surface as runtime_error envelope
              # (this path covers an unexpected raise INSIDE Tools/Sandbox;
              # uncaught raises in JsonRpc dispatch don't reach here).
              stack = __STACKTRACE__

              PtcRunnerMcp.Log.log(:error, "worker_raise", %{
                request_id: request_id,
                kind: error.__struct__ |> inspect(),
                message: Exception.message(error),
                stacktrace: Exception.format_stacktrace(stack)
              })

              # Re-raise so the parent sees a non-:normal DOWN reason and
              # can write the -32603 reply via the DOWN handler.
              :erlang.raise(:error, error, stack)
          end

        send(parent, {:async_reply, request_id, envelope})
      end)

    %{
      state
      | in_flight: Map.put(state.in_flight, request_id, %{pid: worker_pid, ref: ref}),
        workers: Map.put(state.workers, worker_pid, request_id)
    }
  end

  defp remove_in_flight(state, request_id) do
    case Map.pop(state.in_flight, request_id) do
      {nil, _} ->
        state

      {%{pid: pid}, in_flight} ->
        ConcurrencyGate.release()

        %{
          state
          | in_flight: in_flight,
            workers: Map.delete(state.workers, pid)
        }
    end
  end

  # § 6.4 row 3: kill the worker; demonitor; release permit; emit no
  # reply. § 6.4 row 4: unknown request_id is a silent no-op.
  defp cancel_request(state, request_id) do
    case Map.fetch(state.in_flight, request_id) do
      {:ok, %{pid: pid, ref: ref}} ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)

        Log.log(:info, "cancelled_in_flight", %{request_id: request_id})

        # Release happens here — we already demonitored, so the
        # subsequent worker DOWN won't reach our handler.
        ConcurrencyGate.release()

        new_state = %{
          state
          | in_flight: Map.delete(state.in_flight, request_id),
            workers: Map.delete(state.workers, pid)
        }

        maybe_finalize_exit(new_state)

      :error ->
        Log.log(:debug, "cancelled_unknown", %{request_id: request_id})
        state
    end
  end

  # Kill all in-flight workers (stdin EOF, exit grace timeout). Each
  # killed worker's permit is released here (we demonitor first so
  # the DOWN message that arrives later is ignored). No replies
  # written.
  defp cancel_all_workers(state, _reason) do
    Enum.reduce(state.in_flight, state, fn {request_id, %{pid: pid, ref: ref}}, acc ->
      Process.demonitor(ref, [:flush])
      Process.exit(pid, :kill)
      ConcurrencyGate.release()

      %{
        acc
        | in_flight: Map.delete(acc.in_flight, request_id),
          workers: Map.delete(acc.workers, pid)
      }
    end)
  end

  # If we're in `exit_pending` (saw `exit` with workers in flight)
  # and `in_flight` is now empty, finalize exit: notify observer,
  # System.stop in production.
  defp maybe_finalize_exit(%State{exit_pending: true, in_flight: m} = state)
       when map_size(m) == 0 do
    Log.log(:info, "exit_drained", %{})
    notify_observer(state, {:exited, :exit_method})

    if state.observer == nil do
      System.stop(0)
    end

    %{state | exited: true, exit_pending: false}
  end

  defp maybe_finalize_exit(state), do: state

  # ----------------------------------------------------------------
  # JSON-RPC reply construction (kept here so JsonRpc stays pure).
  # ----------------------------------------------------------------

  defp success_reply(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error_reply(id, code, message) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    }
  end
end
