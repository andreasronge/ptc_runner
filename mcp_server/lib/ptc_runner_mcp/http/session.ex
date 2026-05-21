defmodule PtcRunnerMcp.Http.Session do
  @moduledoc false

  use GenServer

  alias PtcRunnerMcp.Http.Telemetry

  alias PtcRunnerMcp.{
    ConcurrencyGate,
    Envelope,
    JsonRpc,
    Limits,
    Log,
    Sessions,
    Version
  }

  defstruct id: nil,
            owner: nil,
            owner_hash: nil,
            protocol_version: Version.primary(),
            max_in_flight: 4,
            in_flight: %{},
            workers: %{},
            draining: false,
            exited: false,
            created_mono: 0,
            last_seen_mono: 0

  @type terminal :: {:reply, map()} | :accepted | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @spec stop(GenServer.server(), term(), timeout()) :: :ok
  def stop(server, reason \\ :normal, timeout \\ 5_000) do
    GenServer.stop(server, reason, timeout)
  end

  @impl GenServer
  def init(opts) do
    now = System.monotonic_time(:millisecond)

    {:ok,
     %__MODULE__{
       id: Keyword.fetch!(opts, :id),
       owner: Keyword.fetch!(opts, :owner),
       owner_hash: Keyword.fetch!(opts, :owner_hash),
       protocol_version: Keyword.fetch!(opts, :protocol_version),
       max_in_flight: Keyword.fetch!(opts, :max_in_flight),
       created_mono: now,
       last_seen_mono: now
     }}
  end

  @spec request(GenServer.server(), map(), keyword(), timeout()) :: terminal()
  def request(server, frame, context \\ [], timeout \\ 5_000) do
    GenServer.call(server, {:request, frame, self(), context}, timeout)
  end

  @spec notify_or_response(GenServer.server(), map(), timeout()) :: :accepted | {:reply, map()}
  def notify_or_response(server, frame, timeout \\ 5_000) do
    GenServer.call(server, {:notify_or_response, frame}, timeout)
  end

  @spec cancel_all(GenServer.server(), term()) :: :ok
  def cancel_all(server, reason) do
    GenServer.call(server, {:cancel_all, reason}, 5_000)
  end

  @spec cancel(GenServer.server(), term(), term()) :: :ok
  def cancel(server, request_id, reason) do
    GenServer.call(server, {:cancel, request_id, reason}, 5_000)
  end

  @spec idle?(GenServer.server(), non_neg_integer(), non_neg_integer()) :: boolean()
  def idle?(server, now_mono, idle_timeout_ms) do
    GenServer.call(server, {:idle?, now_mono, idle_timeout_ms}, 5_000)
  end

  @spec expired?(GenServer.server(), non_neg_integer(), non_neg_integer()) :: boolean()
  def expired?(server, now_mono, ttl_ms) do
    GenServer.call(server, {:expired?, now_mono, ttl_ms}, 5_000)
  end

  @impl GenServer
  def handle_call({:request, frame, waiter, context}, from, state) do
    state = touch(state)

    case dispatch(frame, state, context) do
      {:reply, reply, lifecycle} ->
        reply_with_lifecycle({:reply, reply}, state, lifecycle)

      {:noreply, lifecycle} ->
        reply_with_lifecycle(:accepted, state, lifecycle)

      {:async_call, request_id, work_fn, on_busy, on_discard, lifecycle} ->
        state = apply_lifecycle(state, lifecycle)

        case start_async(state, request_id, work_fn, on_busy, on_discard, waiter, from) do
          {:ok, state} -> {:noreply, state}
          {:reply, reply, state} -> {:reply, {:reply, reply}, state}
        end

      {:cancel, request_id, lifecycle} ->
        {state, _cancelled?} =
          state
          |> apply_lifecycle(lifecycle)
          |> cancel_request(request_id, :client)

        {:reply, :accepted, state}
    end
  end

  def handle_call({:notify_or_response, frame}, _from, state) do
    state = touch(state)

    case classify_response(frame) do
      true ->
        {:reply, :accepted, state}

      false ->
        case dispatch(frame, state, []) do
          {:reply, _reply, lifecycle} ->
            reply_with_lifecycle(:accepted, state, lifecycle)

          {:noreply, lifecycle} ->
            reply_with_lifecycle(:accepted, state, lifecycle)

          {:cancel, request_id, lifecycle} ->
            {state, _} =
              state
              |> apply_lifecycle(lifecycle)
              |> cancel_request(request_id, :client)

            {:reply, :accepted, state}
        end
    end
  end

  def handle_call({:cancel_all, reason}, _from, state) do
    {:reply, :ok, cancel_all_workers(state, reason)}
  end

  def handle_call({:cancel, request_id, reason}, _from, state) do
    {state, _cancelled?} = cancel_request(state, request_id, reason)
    {:reply, :ok, state}
  end

  def handle_call({:idle?, now, timeout_ms}, _from, state) do
    idle? = map_size(state.in_flight) == 0 and now - state.last_seen_mono >= timeout_ms
    {:reply, idle?, state}
  end

  def handle_call({:expired?, now, ttl_ms}, _from, state) do
    {:reply, now - state.created_mono >= ttl_ms, state}
  end

  @impl GenServer
  def handle_info({:async_reply, request_id, envelope}, state) do
    case Map.fetch(state.in_flight, request_id) do
      {:ok, %{ref: ref, waiter_ref: waiter_ref, from: from}} ->
        Log.log(:info, "tools_call_stop", %{
          request_id: request_id,
          is_error: Map.get(envelope, "isError")
        })

        Process.demonitor(ref, [:flush])
        Process.demonitor(waiter_ref, [:flush])
        GenServer.reply(from, {:reply, success_reply(request_id, envelope)})
        {:noreply, state |> remove_in_flight(request_id) |> touch()}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.fetch(state.workers, pid) do
      {:ok, request_id} ->
        reply =
          case reason do
            :killed -> cancelled_reply(request_id)
            :normal -> cancelled_reply(request_id)
            _ -> error_reply(request_id, -32_603, "Internal error")
          end

        from = get_in(state.in_flight, [request_id, :from])
        if from, do: GenServer.reply(from, {:reply, reply})
        {:noreply, state |> remove_in_flight(request_id) |> touch()}

      :error ->
        case find_waiter_request(state, ref) do
          nil ->
            {:noreply, state}

          request_id ->
            {state, _cancelled?} =
              cancel_request(state, request_id, :client_disconnect, reply?: false)

            {:noreply, touch(state)}
        end
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    _ = cancel_all_workers(state, :terminate)
    :ok
  end

  defp dispatch(frame, state, context) do
    frame = maybe_put_http_owner(frame, state.id)

    JsonRpc.dispatch({:ok, frame},
      draining: state.draining,
      protocol_version: state.protocol_version,
      transport: Keyword.get(context, :transport, :http),
      transport_request_id: Keyword.get(context, :transport_request_id),
      owner_hash: Keyword.get(context, :owner_hash, state.owner_hash),
      mcp_session_hash: Keyword.get(context, :mcp_session_hash)
    )
  end

  defp start_async(state, request_id, work_fn, on_busy, on_discard, waiter, from) do
    cond do
      Map.has_key?(state.in_flight, request_id) ->
        safe_invoke(on_discard)
        {:reply, duplicate_reply(request_id), state}

      map_size(state.in_flight) >= state.max_in_flight ->
        Telemetry.emit([:limit, :rejected], %{count: 1}, telemetry_meta(state, :in_flight))
        envelope = Envelope.busy(state.max_in_flight)
        safe_invoke(on_busy, envelope)
        {:reply, success_reply(request_id, envelope), state}

      true ->
        case ConcurrencyGate.try_acquire_tracked(Limits.max_concurrent_calls()) do
          {:ok, permit} ->
            {:ok, spawn_worker(state, request_id, work_fn, on_discard, waiter, from, permit)}

          :full ->
            Telemetry.emit(
              [:limit, :rejected],
              %{count: 1},
              telemetry_meta(state, :global_concurrency)
            )

            envelope = Envelope.busy(Limits.max_concurrent_calls())
            safe_invoke(on_busy, envelope)
            {:reply, success_reply(request_id, envelope), state}
        end
    end
  end

  defp spawn_worker(state, request_id, work_fn, on_discard, waiter, from, permit) do
    parent = self()
    waiter_ref = Process.monitor(waiter)

    {pid, ref} =
      spawn_monitor(fn ->
        envelope = work_fn.()
        send(parent, {:async_reply, request_id, envelope})
      end)

    :ok = ConcurrencyGate.track_worker(permit, pid)

    %{
      state
      | in_flight:
          Map.put(state.in_flight, request_id, %{
            pid: pid,
            ref: ref,
            waiter_ref: waiter_ref,
            from: from,
            permit: permit,
            on_discard: on_discard
          }),
        workers: Map.put(state.workers, pid, request_id)
    }
  end

  defp cancel_request(state, request_id, reason, opts \\ []) do
    case Map.fetch(state.in_flight, request_id) do
      {:ok, %{pid: pid, ref: ref, from: from}} ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)

        if Keyword.get(opts, :reply?, true) do
          GenServer.reply(from, {:reply, cancelled_reply(request_id)})
        end

        Telemetry.emit([:cancelled], %{count: 1}, telemetry_meta(state, reason))
        {remove_in_flight(state, request_id), true}

      :error ->
        {state, false}
    end
  end

  defp cancel_all_workers(state, reason) do
    Enum.reduce(Map.keys(state.in_flight), state, fn request_id, acc ->
      {acc, _} = cancel_request(acc, request_id, reason)
      acc
    end)
  end

  defp remove_in_flight(state, request_id) do
    case Map.pop(state.in_flight, request_id) do
      {nil, _} ->
        state

      {%{pid: pid, waiter_ref: waiter_ref, permit: permit, on_discard: on_discard}, in_flight} ->
        Process.demonitor(waiter_ref, [:flush])
        safe_invoke(on_discard)
        ConcurrencyGate.release_tracked(permit)
        %{state | in_flight: in_flight, workers: Map.delete(state.workers, pid)}
    end
  end

  defp apply_lifecycle(state, :continue), do: state
  defp apply_lifecycle(state, :drain), do: %{state | draining: true}
  defp apply_lifecycle(state, :exit), do: %{state | exited: true}

  defp reply_with_lifecycle(reply, state, lifecycle) do
    state = apply_lifecycle(state, lifecycle)

    case lifecycle do
      :exit -> {:stop, :normal, reply, state}
      _ -> {:reply, reply, state}
    end
  end

  defp touch(state), do: %{state | last_seen_mono: System.monotonic_time(:millisecond)}

  defp find_waiter_request(state, waiter_ref) do
    Enum.find_value(state.in_flight, fn
      {request_id, %{waiter_ref: ^waiter_ref}} -> request_id
      _ -> nil
    end)
  end

  defp classify_response(%{"method" => _}), do: false
  defp classify_response(%{"id" => _, "result" => _}), do: true
  defp classify_response(%{"id" => _, "error" => _}), do: true
  defp classify_response(_), do: false

  defp maybe_put_http_owner(%{"method" => "tools/call", "params" => params} = frame, session_id)
       when is_map(params) do
    args = Map.get(params, "arguments", %{})

    if is_map(args) and Sessions.tool_name?(Map.get(params, "name")) do
      owner = %{transport: :http, mcp_session_id: session_id}
      args = args |> Map.drop(["owner", :owner]) |> Map.put(:owner, owner)
      put_in(frame, ["params", "arguments"], args)
    else
      frame
    end
  end

  defp maybe_put_http_owner(frame, _session_id), do: frame

  defp success_reply(id, result) when is_map(result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => Map.delete(result, "__lisp_debug_structured")}
  end

  defp error_reply(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp duplicate_reply(id) do
    error_reply(id, -32_600, "Invalid Request: id #{inspect(id)} is already in flight")
  end

  defp cancelled_reply(id) do
    success_reply(id, Envelope.cancelled("cancelled"))
  end

  defp telemetry_meta(state, reason) do
    %{
      owner_hash: state.owner_hash,
      session_hash: Telemetry.hash_id(state.id),
      reason: reason,
      limit_name: reason
    }
  end

  defp safe_invoke(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp safe_invoke(fun, arg) when is_function(fun, 1) do
    fun.(arg)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
