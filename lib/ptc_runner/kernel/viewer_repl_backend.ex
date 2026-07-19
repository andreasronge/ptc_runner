defmodule PtcRunner.Kernel.ViewerReplBackend do
  @moduledoc false

  use GenServer

  alias PtcRunner.Kernel.ViewerReplSessionWorker
  alias PtcRunner.Lisp.Formatter

  @start_timeout_ms 20_000
  @operation_timeout_ms 20_000
  @control_timeout_ms 20_000
  @source_limit_bytes 65_536

  @enforce_keys [:pid, :token]
  defstruct [:pid, :token]

  @type t :: %__MODULE__{pid: pid(), token: reference()}

  def start_link(trace_dir, owner) when is_binary(trace_dir) and is_pid(owner) do
    token = make_ref()

    case GenServer.start_link(__MODULE__, {trace_dir, owner, token}) do
      {:ok, pid} -> {:ok, %__MODULE__{pid: pid, token: token}}
      {:error, _reason} -> {:error, :adapter_failure}
    end
  end

  def prepare(backend, session, kind, operation_id),
    do: call(backend, {:prepare, session, kind, operation_id})

  def start_session(backend, operation_id, public_session_id),
    do: call(backend, {:start, operation_id, public_session_id}, :infinity)

  def evaluate(backend, session, operation_id, source),
    do: call(backend, {:evaluate, session, operation_id, source}, :infinity)

  def close_session(backend, session, operation_id),
    do: call(backend, {:close, session, operation_id}, :infinity)

  def reconcile(backend, kind, operation_id),
    do: call(backend, {:reconcile, kind, operation_id}, :infinity)

  def acknowledge(backend, kind, operation_id),
    do: call(backend, {:acknowledge, kind, operation_id})

  def template(backend, session, kind, run_id),
    do: call(backend, {:template, session, kind, run_id})

  def info(backend, session), do: call(backend, {:control, session, :info}, :infinity)

  def abort(backend, session, reason),
    do: call(backend, {:control, session, {:abort, reason}}, :infinity)

  @impl GenServer
  def init({trace_dir, owner, token}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       trace_dir: trace_dir,
       owner: owner,
       owner_ref: Process.monitor(owner),
       token: token,
       operations: %{},
       sessions: %{},
       controls: %{},
       backend_failed?: false
     }}
  end

  @impl GenServer
  def handle_call(
        {token, {:prepare, session, kind, operation_id}},
        _from,
        %{token: token} = state
      ) do
    key = operation_key(kind, operation_id)

    cond do
      state.backend_failed? ->
        {:reply, {:error, :adapter_failure}, state}

      not valid_operation?(kind, operation_id) or not valid_session_binding?(state, session, kind) ->
        {:reply, {:error, :invalid_operation}, state}

      match?(%{session: ^session}, Map.get(state.operations, key)) ->
        {:reply, :ok, state}

      Map.has_key?(state.operations, key) ->
        {:reply, {:error, :invalid_operation}, state}

      operation_kind_active?(state.operations, kind) or map_size(state.operations) >= 3 ->
        {:reply, {:error, :operation_active}, state}

      true ->
        operation = %{kind: kind, session: session, status: :prepared, result: nil}
        {:reply, :ok, put_in(state.operations[key], operation)}
    end
  end

  def handle_call(
        {token, {:start, operation_id, public_session_id}},
        from,
        %{token: token} = state
      ) do
    key = operation_key(:start, operation_id)

    case {Map.get(state.operations, key), valid_id?(public_session_id), map_size(state.sessions)} do
      {%{status: :prepared} = operation, true, 0} ->
        backend = self()

        {worker, worker_ref} =
          spawn_monitor(fn ->
            ViewerReplSessionWorker.run(backend, state.trace_dir, public_session_id)
          end)

        timer = Process.send_after(self(), {:operation_timeout, key}, @start_timeout_ms)

        operation =
          Map.merge(operation, %{
            status: :running,
            callers: [from],
            worker: worker,
            worker_ref: worker_ref,
            timer: timer,
            public_session_id: public_session_id
          })

        {:noreply, put_in(state.operations[key], operation)}

      {%{status: :sealed_not_started}, true, _count} ->
        {:reply, {:error, :not_started}, state}

      {%{public_session_id: ^public_session_id, result: result}, true, _count}
      when not is_nil(result) ->
        {:reply, result, state}

      {%{result: result}, true, _count} when not is_nil(result) ->
        {:reply, {:error, :invalid_operation}, state}

      {_operation, false, _count} ->
        {:reply, {:error, :invalid_operation}, state}

      {%{status: :prepared}, true, _count} ->
        {:reply, {:error, :operation_active}, state}

      _ ->
        {:reply, {:error, :operation_not_prepared}, state}
    end
  end

  def handle_call(
        {token, {:evaluate, session_ref, operation_id, source}},
        from,
        %{token: token} = state
      )
      when is_binary(source) do
    cond do
      byte_size(source) > @source_limit_bytes ->
        {:reply, {:error, :source_too_large}, state}

      not String.valid?(source) ->
        {:reply, {:error, :invalid_source}, state}

      true ->
        dispatch_session_operation(
          state,
          from,
          :evaluation,
          session_ref,
          operation_id,
          {:evaluate, source}
        )
    end
  end

  def handle_call(
        {token, {:evaluate, _session_ref, _operation_id, _source}},
        _from,
        %{token: token} = state
      ),
      do: {:reply, {:error, :invalid_source}, state}

  def handle_call(
        {token, {:close, session_ref, operation_id}},
        from,
        %{token: token} = state
      ) do
    dispatch_session_operation(state, from, :close, session_ref, operation_id, :close)
  end

  def handle_call({token, {:reconcile, kind, operation_id}}, from, %{token: token} = state) do
    {operation_kind, expected_session} = reconcile_kind(kind)
    key = operation_key(operation_kind, operation_id)

    case Map.get(state.operations, key) do
      %{session: session, result: result}
      when not is_nil(result) and
             (is_nil(expected_session) or session == expected_session) ->
        {:reply, result, state}

      %{status: :running, session: session} = operation
      when is_nil(expected_session) or session == expected_session ->
        operation = Map.update!(operation, :callers, &[from | &1])
        {:noreply, put_in(state.operations[key], operation)}

      %{status: :cancelling, session: session} = operation
      when is_nil(expected_session) or session == expected_session ->
        operation = Map.update!(operation, :callers, &[from | &1])
        {:noreply, put_in(state.operations[key], operation)}

      %{status: :prepared, session: session} = operation
      when is_nil(expected_session) or session == expected_session ->
        sealed = if operation_kind == :start, do: :sealed_not_started, else: :sealed_not_accepted

        result =
          if operation_kind == :start, do: {:error, :not_started}, else: {:error, :not_accepted}

        operation = %{operation | status: sealed, result: result}
        {:reply, result, put_in(state.operations[key], operation)}

      _ ->
        {:reply, {:error, :adapter_failure}, state}
    end
  end

  def handle_call(
        {token, {:acknowledge, kind, operation_id}},
        _from,
        %{token: token} = state
      ) do
    key = operation_key(kind, operation_id)

    case Map.pop(state.operations, key) do
      {nil, _operations} ->
        {:reply, :ok, state}

      {%{status: status}, _operations}
      when status in [:prepared, :running, :cancelling] ->
        {:reply, {:error, :operation_active}, state}

      {%{kind: :close, session: session_ref, result: {:ok, _info}}, operations} ->
        {session, sessions} = Map.pop(state.sessions, session_ref)
        stop_session_worker(session)
        {:reply, :ok, %{state | operations: operations, sessions: sessions}}

      {_operation, operations} ->
        {:reply, :ok, %{state | operations: operations}}
    end
  end

  def handle_call(
        {token, {:template, session_ref, kind, run_id}},
        _from,
        %{token: token} = state
      ) do
    if Map.has_key?(state.sessions, session_ref) and kind in [:run, :turns] and
         valid_run_id?(run_id) do
      args = [{:string, run_id}] ++ if(kind == :turns, do: [{:map, []}], else: [])
      source = Formatter.format({:list, [{:ns_symbol, :log, kind} | args]})
      {:reply, {:ok, %{source: source}}, state}
    else
      {:reply, {:error, :invalid_template}, state}
    end
  end

  def handle_call(
        {token, {:control, session_ref, request}},
        from,
        %{token: token} = state
      )
      when request == :info or
             (is_tuple(request) and tuple_size(request) == 2 and elem(request, 0) == :abort and
                is_atom(elem(request, 1))) do
    case Map.get(state.sessions, session_ref) do
      %{worker: worker} ->
        control_ref = make_ref()
        timer = Process.send_after(self(), {:control_timeout, control_ref}, @control_timeout_ms)
        send(worker, {:control, control_ref, request})

        control = %{
          from: from,
          session: session_ref,
          worker: worker,
          timer: timer,
          status: :running
        }

        {:noreply, put_in(state.controls[control_ref], control)}

      nil ->
        {:reply, {:error, :session_closed}, state}
    end
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :adapter_failure}, state}

  @impl GenServer
  def handle_info({:viewer_repl_started, worker, result}, state) do
    key = running_start_key(state.operations, worker)
    {:noreply, complete_start(state, key, worker, result)}
  end

  def handle_info({:viewer_repl_operation, worker, key, result}, state) do
    {:noreply, complete_session_operation(state, key, worker, result)}
  end

  def handle_info({:viewer_repl_control, worker, control_ref, result}, state) do
    {:noreply, complete_control(state, control_ref, worker, result)}
  end

  def handle_info({:operation_timeout, key}, state) do
    case Map.get(state.operations, key) do
      %{status: :running, worker: worker} = operation ->
        Process.exit(worker, :kill)
        operation = operation |> cancel_operation_timer() |> Map.put(:status, :cancelling)
        {:noreply, %{put_in(state.operations[key], operation) | backend_failed?: true}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:control_timeout, control_ref}, state) do
    case Map.pop(state.controls, control_ref) do
      {nil, _controls} ->
        {:noreply, state}

      {%{worker: worker} = control, controls} ->
        Process.exit(worker, :kill)
        control = %{control | timer: nil, status: :cancelling}

        {:noreply,
         %{state | controls: Map.put(controls, control_ref, control), backend_failed?: true}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, worker, _reason}, state) do
    {:noreply, worker_down(state, worker, ref)}
  end

  def handle_info({:EXIT, owner, _reason}, %{owner: owner} = state), do: {:stop, :normal, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: redact_status(status)
  else
    def format_status(status), do: redact_status(status)
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]

  @impl GenServer
  def terminate(_reason, state) do
    workers =
      Enum.flat_map(state.sessions, fn {_session_ref, session} -> [session.worker] end) ++
        Enum.flat_map(state.operations, fn {_key, operation} -> [Map.get(operation, :worker)] end) ++
        Enum.flat_map(state.controls, fn {_ref, control} -> [control.worker] end)

    workers
    |> Enum.filter(&is_pid/1)
    |> Enum.uniq()
    |> Enum.each(&Process.exit(&1, :kill))

    :ok
  end

  defp dispatch_session_operation(state, from, kind, session_ref, operation_id, command) do
    key = operation_key(kind, operation_id)
    request_identity = operation_request_identity(command)

    case {Map.get(state.operations, key), Map.get(state.sessions, session_ref)} do
      {%{status: :prepared, session: ^session_ref} = operation, %{worker: worker}} ->
        timer = Process.send_after(self(), {:operation_timeout, key}, @operation_timeout_ms)
        send(worker, {:operation, key, command})

        operation =
          Map.merge(operation, %{
            status: :running,
            callers: [from],
            worker: worker,
            timer: timer,
            request_identity: request_identity
          })

        {:noreply, put_in(state.operations[key], operation)}

      {%{session: ^session_ref, request_identity: ^request_identity, result: result}, _session}
      when not is_nil(result) ->
        {:reply, result, state}

      {%{session: ^session_ref, result: result}, _session} when not is_nil(result) ->
        {:reply, {:error, :invalid_operation}, state}

      {%{session: ^session_ref, status: :sealed_not_accepted}, _session} ->
        {:reply, {:error, :not_accepted}, state}

      _ ->
        {:reply, {:error, :operation_not_prepared}, state}
    end
  end

  defp complete_start(state, nil, _worker, _result), do: state

  defp complete_start(state, key, worker, {:ok, info}) do
    operation = Map.fetch!(state.operations, key)
    session_ref = random_id()
    result = {:ok, session_ref, info}
    reply_callers(operation.callers, result)

    operation =
      operation
      |> cancel_operation_timer()
      |> Map.merge(%{status: :finished, result: result, callers: []})

    session = %{
      worker: worker,
      worker_ref: operation.worker_ref,
      public_session_id: operation.public_session_id
    }

    state
    |> put_in([:operations, key], operation)
    |> put_in([:sessions, session_ref], session)
  end

  defp complete_start(state, key, _worker, {:error, reason}) do
    complete_operation(state, key, {:error, normalize_start_error(reason)})
  end

  defp complete_start(state, key, _worker, _invalid),
    do: complete_operation(state, key, {:error, :repl_start_failed})

  defp complete_session_operation(state, key, worker, result) do
    case Map.get(state.operations, key) do
      %{status: :running, worker: ^worker} ->
        complete_operation(state, key, normalize_result(result))

      _ ->
        state
    end
  end

  defp complete_operation(state, key, result) do
    operation = Map.fetch!(state.operations, key)
    reply_callers(operation.callers, result)

    operation =
      operation
      |> cancel_operation_timer()
      |> Map.merge(%{status: :finished, result: result, callers: []})

    put_in(state.operations[key], operation)
  end

  defp complete_control(state, control_ref, worker, result) do
    case Map.pop(state.controls, control_ref) do
      {%{from: from, worker: ^worker, status: :running} = control, controls} ->
        cancel_timer(control.timer)
        GenServer.reply(from, normalize_result(result))
        %{state | controls: controls}

      {%{worker: ^worker, status: :cancelling} = control, controls} ->
        %{state | controls: Map.put(controls, control_ref, control)}

      _ ->
        state
    end
  end

  defp worker_down(state, worker, worker_ref) do
    {dead_sessions, sessions} =
      Enum.split_with(state.sessions, fn {_ref, session} ->
        session.worker == worker and session.worker_ref == worker_ref
      end)

    state = %{
      state
      | sessions: Map.new(sessions),
        backend_failed?: state.backend_failed? or dead_sessions != []
    }

    state =
      Enum.reduce(state.operations, state, fn {key, operation}, acc ->
        cond do
          operation.status in [:running, :cancelling] and
              Map.get(operation, :worker) == worker ->
            complete_operation(acc, key, {:error, :adapter_failure})

          operation.kind == :start and Map.get(operation, :worker) == worker and
              match?({:ok, _session_ref, _info}, operation.result) ->
            failed = %{operation | status: :finished, result: {:error, :adapter_failure}}
            put_in(acc.operations[key], failed)

          true ->
            acc
        end
      end)

    {dead_controls, controls} =
      Enum.split_with(state.controls, fn {_ref, control} -> control.worker == worker end)

    Enum.each(dead_controls, fn {_ref, control} ->
      cancel_timer(control.timer)
      GenServer.reply(control.from, {:error, :adapter_failure})
    end)

    %{state | controls: Map.new(controls)}
  end

  defp running_start_key(operations, worker) do
    Enum.find_value(operations, fn
      {{:start, _id} = key, %{status: :running, worker: ^worker}} -> key
      _entry -> nil
    end)
  end

  defp stop_session_worker(%{worker: worker}) when is_pid(worker),
    do: send(worker, {:stop, :viewer_shutdown})

  defp stop_session_worker(_session), do: :ok

  defp valid_operation?(kind, operation_id),
    do: kind in [:start, :evaluation, :close] and valid_id?(operation_id)

  defp valid_session_binding?(state, nil, :start), do: map_size(state.sessions) == 0

  defp valid_session_binding?(state, session, kind) when kind in [:evaluation, :close],
    do: is_binary(session) and Map.has_key?(state.sessions, session)

  defp valid_session_binding?(_state, _session, _kind), do: false

  defp operation_kind_active?(operations, kind),
    do:
      Enum.any?(operations, fn {{operation_kind, _id}, _operation} -> operation_kind == kind end)

  defp reconcile_kind(:start), do: {:start, nil}
  defp reconcile_kind({:evaluation, session}), do: {:evaluation, session}
  defp reconcile_kind({:close, session}), do: {:close, session}

  defp operation_key(kind, operation_id), do: {kind, operation_id}

  defp valid_run_id?(run_id),
    do: is_binary(run_id) and String.valid?(run_id) and byte_size(run_id) in 1..512

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, id)
  defp random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp operation_request_identity({:evaluate, source}) when is_binary(source),
    do: {:source_sha256, :crypto.hash(:sha256, source)}

  defp operation_request_identity(:close), do: :close

  defp normalize_result({:ok, result}) when is_map(result), do: {:ok, result}
  defp normalize_result({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize_result(_result), do: {:error, :adapter_failure}

  defp normalize_start_error(reason)
       when reason in [
              :source_changed,
              :source_limit_exceeded,
              :source_retained_limit_exceeded,
              :malformed_source,
              :unsupported_version,
              :source_unavailable
            ],
       do: reason

  defp normalize_start_error(_reason), do: :repl_start_failed

  defp reply_callers(callers, result), do: Enum.each(callers, &GenServer.reply(&1, result))

  defp cancel_operation_timer(operation) do
    cancel_timer(Map.get(operation, :timer))
    Map.put(operation, :timer, nil)
  end

  defp cancel_timer(timer) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_timer(_timer), do: false

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end

  defp call(%__MODULE__{pid: pid, token: token}, request, timeout \\ 5_000) do
    GenServer.call(pid, {token, request}, timeout)
  catch
    :exit, _reason -> {:error, :adapter_failure}
  end
end
