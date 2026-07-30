defmodule PtcRunner.Kernel.MCPRequestContext do
  @moduledoc false

  use GenServer

  alias PtcRunner.Kernel.MCPOAuth.TokenManager

  @release_timeout_ms 5_000
  @initial_release_retry_ms 250
  @maximum_release_retry_ms 30_000

  @enforce_keys [:pid]
  defstruct [:pid, :authorization]

  @type t :: %__MODULE__{pid: pid(), authorization: TokenManager.t() | nil}

  @spec start(keyword()) :: {:ok, t()}
  def start(opts) do
    owner = Keyword.fetch!(opts, :owner)
    endpoint = Keyword.fetch!(opts, :endpoint)
    headers = Keyword.fetch!(opts, :headers)
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    authorization = Keyword.get(opts, :authorization)

    true = is_nil(authorization) or match?(%TokenManager{}, authorization)

    {:ok, pid} =
      GenServer.start(
        __MODULE__,
        {owner, endpoint, headers, timeout_ms, authorization}
      )

    {:ok, %__MODULE__{pid: pid, authorization: authorization}}
  end

  @spec begin_request(t()) ::
          {:ok, map()} | {:error, :closed | :timeout | :mcp_authorization_required}
  def begin_request(%__MODULE__{pid: pid}) do
    case safe_call(pid, :begin_request, :infinity) do
      {:ok, request} ->
        {:ok, request}

      {:error, :mcp_transport_error} ->
        {:error, :closed}

      {:error, reason} = error ->
        if reason == :mcp_timeout, do: {:error, :timeout}, else: error
    end
  end

  @spec finish_request(t()) :: :ok
  def finish_request(%__MODULE__{pid: pid}) do
    case safe_call(pid, :finish_request) do
      :ok ->
        :ok

      {:release, release, request_id} ->
        release_and_ack(pid, release, request_id)

      {:error, :timeout} ->
        fence_request_worker()

      {:error, :closed} ->
        fence_request_worker()
    end
  end

  @spec close(t()) :: :ok | {:error, :mcp_transport_error}
  def close(%__MODULE__{pid: pid, authorization: authorization}) do
    ref = Process.monitor(pid)

    context_result =
      try do
        case safe_call(pid, :close, @release_timeout_ms) do
          :ok ->
            receive do
              {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
            after
              1_000 -> {:error, :mcp_transport_error}
            end

          {:error, :closed} ->
            if Process.alive?(pid), do: {:error, :mcp_transport_error}, else: :ok

          {:error, :timeout} ->
            {:error, :mcp_transport_error}
        end
      after
        Process.demonitor(ref, [:flush])
      end

    authorization_result =
      if context_result == :ok and match?(%TokenManager{}, authorization),
        do: TokenManager.close(authorization),
        else: context_result

    case {context_result, authorization_result} do
      {:ok, :ok} -> :ok
      _failure -> {:error, :mcp_transport_error}
    end
  end

  @impl GenServer
  def init({owner, endpoint, headers, timeout_ms, authorization}) do
    {:ok,
     %{
       owner_ref: Process.monitor(owner),
       endpoint: endpoint,
       headers: headers,
       timeout_ms: timeout_ms,
       authorization: authorization,
       next_id: 1,
       active: %{},
       release_workers: %{},
       closing: nil
     }}
  end

  @impl GenServer
  def handle_call(:begin_request, _from, %{closing: closing} = state)
      when not is_nil(closing),
      do: {:reply, {:error, :closed}, state}

  def handle_call(:begin_request, {caller, _tag} = from, state) do
    deadline_ms = System.monotonic_time(:millisecond) + state.timeout_ms

    request = %{
      endpoint: state.endpoint,
      headers: state.headers,
      timeout_ms: state.timeout_ms,
      deadline_ms: deadline_ms,
      authorization_manager: state.authorization,
      id: state.next_id
    }

    entry = %{
      ref: Process.monitor(caller),
      id: state.next_id,
      issued: nil,
      deadline_ms: deadline_ms,
      authorization_ref: nil,
      from: nil,
      caller_down: false
    }

    state = %{state | next_id: state.next_id + 1, active: Map.put(state.active, caller, entry)}

    case state.authorization do
      nil ->
        {:reply, {:ok, Map.delete(request, :authorization_manager)}, state}

      %TokenManager{} ->
        context = self()
        id = request.id

        {_worker, authorization_ref} =
          spawn_monitor(fn ->
            result = authorize(request, caller)
            send(context, {:authorization_finished, caller, id, result})
          end)

        state =
          state
          |> put_in([:active, caller, :authorization_ref], authorization_ref)
          |> put_in([:active, caller, :from], from)

        {:noreply, state}
    end
  end

  def handle_call(:finish_request, {caller, _tag}, state) do
    case {state.authorization, Map.get(state.active, caller)} do
      {%TokenManager{}, %{id: id, issued: %{release: release}}} ->
        {:reply, {:release, release, id}, state}

      _none ->
        {_active, state} = pop_active(state, caller)
        finish_or_continue(state, :ok)
    end
  end

  def handle_call({:release_finished, id}, {caller, _tag}, state) do
    case state.active do
      %{^caller => %{id: ^id}} ->
        {_active, state} = pop_active(state, caller)
        finish_or_continue(state, :ok)

      _closed_or_stale ->
        {:reply, {:error, :closed}, state}
    end
  end

  def handle_call(:close, from, %{closing: {reason, waiters}} = state) do
    {:noreply, %{state | closing: {reason, [from | waiters]}}}
  end

  def handle_call(:close, from, state) do
    state = %{state | closing: {:close, [from]}}
    kill_active(state.active)

    if map_size(state.active) == 0,
      do: stop_and_reply(state),
      else: {:noreply, state}
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :closed}, state}

  @impl GenServer
  def handle_cast(_request, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    state = %{state | closing: state.closing || {:owner_down, []}}
    kill_active(state.active)

    if map_size(state.active) == 0,
      do: stop_and_reply(state),
      else: {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case state.active do
      %{^pid => %{ref: ^ref, authorization_ref: authorization_ref} = entry}
      when is_reference(authorization_ref) ->
        state =
          put_in(
            state.active[pid],
            %{entry | ref: nil, from: nil, caller_down: true}
          )

        {:noreply, state}

      %{^pid => %{ref: ^ref, issued: %{release: release}} = entry} ->
        state
        |> put_in([:active, pid], %{entry | ref: nil})
        |> start_detached_release(pid, entry.id, release, @initial_release_retry_ms)

      %{^pid => %{ref: ^ref}} ->
        state |> release_active(pid, false) |> close_or_continue()

      _active ->
        case handle_authorization_worker_down(state, ref) do
          :not_authorization_worker -> handle_release_worker_down(state, ref)
          result -> result
        end
    end
  end

  def handle_info({:authorization_finished, caller, id, result}, state) do
    case Map.get(state.active, caller) do
      %{id: ^id, authorization_ref: authorization_ref} = entry
      when is_reference(authorization_ref) ->
        Process.demonitor(authorization_ref, [:flush])

        state =
          state
          |> put_in([:active, caller, :authorization_ref], nil)
          |> put_in([:active, caller, :from], nil)

        finish_authorization(state, caller, entry, result)

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:detached_release_finished, operation_ref, result}, state) do
    case Map.pop(state.release_workers, operation_ref) do
      {nil, _workers} ->
        {:noreply, state}

      {%{monitor_ref: monitor_ref, caller: caller, id: id, release: release, retry_ms: retry_ms},
       workers} ->
        Process.demonitor(monitor_ref, [:flush])
        state = %{state | release_workers: workers}

        case {result, Map.get(state.active, caller)} do
          {:ok, %{id: ^id}} ->
            state |> release_active(caller, false) |> close_or_continue()

          {{:error, _reason}, %{id: ^id}} ->
            schedule_detached_release(state, caller, id, release, retry_ms)

          {_result, _stale} ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:retry_detached_release, caller, id, release, retry_ms}, state) do
    case Map.get(state.active, caller) do
      %{id: ^id} ->
        start_detached_release(state, caller, id, release, retry_ms)

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: redact_status(status)
  else
    def format_status(status), do: redact_status(status)
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]

  defp safe_call(pid, request, timeout \\ 5_000) do
    GenServer.call(pid, request, timeout)
  catch
    :exit, {:timeout, _detail} -> {:error, :timeout}
    :exit, {:noproc, _detail} -> {:error, :closed}
    :exit, {:normal, _detail} -> {:error, :closed}
    :exit, _reason -> {:error, :closed}
  end

  defp fence_request_worker do
    Process.exit(self(), :kill)
  end

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end

  defp release_active(state, caller, demonitor? \\ true) do
    {entry, active} = Map.pop(state.active, caller)
    ref = if is_map(entry), do: entry.ref, else: nil
    if demonitor? and is_reference(ref), do: Process.demonitor(ref, [:flush])
    %{state | active: active}
  end

  defp pop_active(state, caller) do
    entry = Map.get(state.active, caller)
    {entry, release_active(state, caller)}
  end

  defp finish_or_continue(%{active: active, closing: {_reason, _waiters}} = state, reply)
       when map_size(active) == 0 do
    reply_waiters(state)
    {:stop, :normal, reply, state}
  end

  defp finish_or_continue(state, reply), do: {:reply, reply, state}

  defp close_or_continue(%{active: active, closing: nil} = state) when map_size(active) == 0,
    do: {:noreply, state}

  defp close_or_continue(%{active: active, closing: {_reason, _waiters}} = state)
       when map_size(active) == 0,
       do: stop_and_reply(state)

  defp close_or_continue(state), do: {:noreply, state}

  defp stop_and_reply(state) do
    reply_waiters(state)
    {:stop, :normal, state}
  end

  defp reply_waiters(%{closing: {_reason, waiters}}),
    do: Enum.each(waiters, &GenServer.reply(&1, :ok))

  defp kill_active(active),
    do: Enum.each(Map.keys(active), &Process.exit(&1, :kill))

  defp authorize(%{authorization_manager: nil} = request, _admission_owner),
    do: {:ok, Map.delete(request, :authorization_manager)}

  defp authorize(
         %{authorization_manager: %TokenManager{} = manager} = request,
         admission_owner
       ) do
    case TokenManager.authorization_header(manager, request.deadline_ms, admission_owner) do
      {:ok, issued} ->
        remaining_ms =
          max(request.deadline_ms - System.monotonic_time(:millisecond), 1)

        {:ok,
         request
         |> Map.update!(:headers, &(&1 ++ [issued.header]))
         |> Map.put(:timeout_ms, remaining_ms)
         |> Map.put(:authorization, %{
           manager: manager,
           generation: issued.generation,
           admission: issued.admission,
           egress: issued.egress,
           release: issued.release
         })
         |> Map.delete(:authorization_manager)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_authorization(state, caller, entry, {:ok, %{authorization: issued} = request}) do
    state = put_in(state.active[caller].issued, issued)

    if entry.caller_down do
      start_detached_release(
        state,
        caller,
        entry.id,
        issued.release,
        @initial_release_retry_ms
      )
    else
      GenServer.reply(entry.from, {:ok, request})
      {:noreply, state}
    end
  end

  defp finish_authorization(state, caller, entry, {:error, _reason} = error) do
    if not entry.caller_down, do: GenServer.reply(entry.from, error)
    state |> release_active(caller, false) |> close_or_continue()
  end

  defp handle_authorization_worker_down(state, monitor_ref) do
    case Enum.find(state.active, fn
           {_caller, %{authorization_ref: ^monitor_ref}} -> true
           _entry -> false
         end) do
      {caller, entry} ->
        if not entry.caller_down,
          do: GenServer.reply(entry.from, {:error, :mcp_transport_error})

        state
        |> release_active(caller, false)
        |> close_or_continue()

      nil ->
        :not_authorization_worker
    end
  end

  defp release_and_ack(pid, release, request_id) do
    release_deadline_ms =
      System.monotonic_time(:millisecond) + @release_timeout_ms

    with :ok <- safe_release(release, release_deadline_ms),
         :ok <- safe_call(pid, {:release_finished, request_id}) do
      :ok
    else
      _release_not_acknowledged -> fence_request_worker()
    end
  end

  defp start_detached_release(state, caller, id, release, retry_ms) do
    context = self()
    operation_ref = make_ref()

    {_worker, monitor_ref} =
      spawn_monitor(fn ->
        deadline_ms = System.monotonic_time(:millisecond) + @release_timeout_ms
        result = safe_release(release, deadline_ms)
        send(context, {:detached_release_finished, operation_ref, result})
      end)

    worker = %{
      monitor_ref: monitor_ref,
      caller: caller,
      id: id,
      release: release,
      retry_ms: min(retry_ms * 2, @maximum_release_retry_ms)
    }

    {:noreply, put_in(state.release_workers[operation_ref], worker)}
  end

  defp handle_release_worker_down(state, monitor_ref) do
    case Enum.find(state.release_workers, fn
           {_operation_ref, %{monitor_ref: ^monitor_ref}} -> true
           _worker -> false
         end) do
      {operation_ref, %{caller: caller, id: id, release: release, retry_ms: retry_ms}} ->
        workers = Map.delete(state.release_workers, operation_ref)

        schedule_detached_release(
          %{state | release_workers: workers},
          caller,
          id,
          release,
          retry_ms
        )

      nil ->
        {:noreply, state}
    end
  end

  defp schedule_detached_release(state, caller, id, release, retry_ms) do
    Process.send_after(
      self(),
      {:retry_detached_release, caller, id, release, retry_ms},
      retry_ms
    )

    {:noreply, state}
  end

  defp safe_release(release, deadline_ms) when is_function(release, 1) do
    case release.(deadline_ms) do
      :ok -> :ok
      {:error, _reason} = error -> error
      _invalid -> {:error, :store_error}
    end
  rescue
    _exception -> {:error, :store_error}
  catch
    _kind, _reason -> {:error, :store_error}
  end
end
