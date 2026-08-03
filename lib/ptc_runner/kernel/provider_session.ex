defmodule PtcRunner.Kernel.ProviderSession do
  @moduledoc """
  One owner-backed cleanup stack for a command's active provider work.

  A session initially monitors its build creator and owns every acquisition
  scope opened through `PtcRunner.Kernel.ResourceRegistrar`. Before provider
  callbacks can start, execution binds the session exactly once to its lifecycle
  owner and run state. The session then tracks every provider task itself, so
  owner or run-state death drains live tasks before any provider closer runs.
  Each scope starts provisional, activates immediately before acquisition, and
  is either committed with one provider close operation or aborted. Normal
  close and lifecycle-owner death drain committed scopes in reverse commit
  order, then discard remaining provisional scopes in reverse creation order.

  Cleanup shares the sealed `provider_cleanup_timeout_ms` deadline and runs
  each close operation in a heap-bounded worker. Failures never stop later
  cleanup attempts. This is a process-local ownership boundary, not a durable
  resource journal or a security boundary against trusted code in the same VM.
  """

  use GenServer

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.BoundedWorker
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.ResourceRegistrar

  @enforce_keys [
    :pid,
    :token,
    :creator,
    :cleanup_timeout_ms,
    :max_heap_words,
    :attestation
  ]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @opaque t :: %__MODULE__{
            pid: pid(),
            token: reference(),
            creator: pid(),
            cleanup_timeout_ms: pos_integer(),
            max_heap_words: pos_integer(),
            attestation: binary()
          }

  @spec start(Limits.t()) :: {:ok, t()} | {:error, term()}
  def start(%Limits{} = limits) do
    if Limits.valid?(limits) do
      creator = self()
      token = make_ref()

      case GenServer.start(__MODULE__, {creator, token, limits}) do
        {:ok, pid} ->
          session = %__MODULE__{
            pid: pid,
            token: token,
            creator: creator,
            cleanup_timeout_ms: limits.provider_cleanup_timeout_ms,
            max_heap_words: limits.provider_heap_words,
            attestation: <<>>
          }

          {:ok, %{session | attestation: Attestation.attest(__MODULE__, payload(session))}}

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :invalid_provider_session}
    end
  end

  def start(_limits), do: {:error, :invalid_provider_session}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = session),
    do:
      Enum.sort(Map.keys(session)) == @field_keys and is_pid(session.pid) and
        is_reference(session.token) and is_pid(session.creator) and
        Attestation.valid?(__MODULE__, payload(session), session.attestation)

  def valid?(_session), do: false

  @doc false
  @spec compatible_limits?(term(), term()) :: boolean()
  def compatible_limits?(%__MODULE__{} = session, %Limits{} = limits) do
    valid?(session) and Limits.valid?(limits) and
      session.cleanup_timeout_ms == limits.provider_cleanup_timeout_ms and
      session.max_heap_words == limits.provider_heap_words
  end

  def compatible_limits?(_session, _limits), do: false

  @spec open_registrar(t()) ::
          {:ok, ResourceRegistrar.t()} | {:error, :provider_session_unavailable}
  def open_registrar(%__MODULE__{} = session) do
    if valid?(session) and session.creator == self() do
      case call(session.pid, {session.token, :open_registrar}, 5_000) do
        {:ok, scope} -> {:ok, ResourceRegistrar.new(session.pid, session.token, scope)}
        _failure -> {:error, :provider_session_unavailable}
      end
    else
      {:error, :provider_session_unavailable}
    end
  end

  def open_registrar(_session), do: {:error, :provider_session_unavailable}

  @spec close(t()) :: :ok | {:error, :provider_cleanup_failed}
  def close(%__MODULE__{} = session) do
    if valid?(session) do
      call(
        session.pid,
        {session.token, :close},
        :infinity,
        {:error, :provider_cleanup_failed}
      )
    else
      {:error, :provider_cleanup_failed}
    end
  end

  def close(_session), do: {:error, :provider_cleanup_failed}

  @doc false
  @spec close_with_unregistered(t(), (-> term()) | nil) ::
          :ok | {:error, :provider_cleanup_failed}
  def close_with_unregistered(%__MODULE__{} = session, close)
      when is_function(close, 0) or is_nil(close) do
    if valid?(session) do
      case call(
             session.pid,
             {session.token, {:close_with_unregistered, close}},
             :infinity,
             :session_unavailable
           ) do
        :session_unavailable -> close_after_session_loss(session, close)
        result -> result
      end
    else
      {:error, :provider_cleanup_failed}
    end
  end

  def close_with_unregistered(_session, _close), do: {:error, :provider_cleanup_failed}

  @doc false
  @spec bind_lifecycle(t(), pid(), pid()) ::
          :ok | {:error, :provider_session_unavailable}
  def bind_lifecycle(%__MODULE__{} = session, owner, run_state)
      when is_pid(owner) and is_pid(run_state) do
    if valid?(session) do
      call(
        session.pid,
        {session.token, {:bind_lifecycle, owner, run_state}},
        5_000,
        {:error, :provider_session_unavailable}
      )
    else
      {:error, :provider_session_unavailable}
    end
  end

  def bind_lifecycle(_session, _owner, _run_state),
    do: {:error, :provider_session_unavailable}

  @doc false
  @spec attach_provider(t(), pid()) :: :ok | {:error, :closed | :provider_down}
  def attach_provider(%__MODULE__{} = session, provider) when is_pid(provider) do
    if valid?(session) do
      call(
        session.pid,
        {session.token, {:attach_provider, provider}},
        :infinity,
        {:error, :closed}
      )
    else
      {:error, :closed}
    end
  end

  @doc false
  @spec drain_provider_tasks(t()) :: :ok
  def drain_provider_tasks(%__MODULE__{} = session) do
    if valid?(session) do
      call(session.pid, {session.token, :drain_provider_tasks}, :infinity, :ok)
    else
      :ok
    end
  end

  def drain_provider_tasks(_session), do: :ok

  @doc false
  def activate_registrar(%ResourceRegistrar{} = registrar),
    do: registrar_call(registrar, :activate, {:error, :resource_registrar_unavailable})

  @doc false
  def commit_registrar(%ResourceRegistrar{} = registrar, close)
      when is_function(close, 0) or is_nil(close),
      do:
        registrar_call(
          registrar,
          {:commit, close},
          {:error, :resource_registrar_unavailable}
        )

  def commit_registrar(_registrar, _close), do: {:error, :resource_registrar_unavailable}

  @doc false
  def abort_registrar(%ResourceRegistrar{} = registrar),
    do: registrar_call(registrar, :abort, {:error, :provider_cleanup_failed})

  @impl true
  def init({creator, token, %Limits{} = limits}) do
    {:ok,
     %{
       owner: creator,
       owner_monitor: Process.monitor(creator),
       token: token,
       cleanup_timeout_ms: limits.provider_cleanup_timeout_ms,
       cleanup_deadline: nil,
       max_heap_words: limits.provider_heap_words,
       lifecycle_bound?: false,
       run_state: nil,
       run_state_monitor: nil,
       providers: %{},
       scopes: %{},
       scope_order: [],
       committed: []
     }}
  end

  @impl true
  def handle_call({token, :open_registrar}, {creator, _tag}, state)
      when token == state.token and creator == state.owner do
    scope = make_ref()
    entry = %{phase: :inactive, close: nil}

    {:reply, {:ok, scope},
     %{
       state
       | scopes: Map.put(state.scopes, scope, entry),
         scope_order: [scope | state.scope_order]
     }}
  end

  def handle_call({token, {:registrar, scope, :activate}}, _from, state)
      when token == state.token do
    case Map.fetch(state.scopes, scope) do
      {:ok, %{phase: :inactive} = entry} ->
        {:reply, :ok, put_in(state.scopes[scope], %{entry | phase: :active})}

      _missing_or_closed ->
        {:reply, {:error, :resource_registrar_unavailable}, state}
    end
  end

  def handle_call({token, {:registrar, scope, {:commit, close}}}, _from, state)
      when token == state.token do
    case Map.fetch(state.scopes, scope) do
      {:ok, %{phase: :active} = entry} when is_function(close, 0) or is_nil(close) ->
        entry = %{entry | phase: :committed, close: close}

        {:reply, :ok,
         %{put_in(state.scopes[scope], entry) | committed: [scope | state.committed]}}

      _missing_or_closed ->
        {:reply, {:error, :resource_registrar_unavailable}, state}
    end
  end

  def handle_call({token, {:registrar, scope, :abort}}, _from, state)
      when token == state.token do
    {result, state} = abort_scope(scope, state)
    {:reply, result, state}
  end

  def handle_call(
        {token, {:bind_lifecycle, owner, run_state}},
        _from,
        %{token: token, lifecycle_bound?: false} = state
      )
      when is_pid(owner) and is_pid(run_state) do
    if Process.alive?(owner) and Process.alive?(run_state) do
      Process.demonitor(state.owner_monitor, [:flush])

      {:reply, :ok,
       %{
         state
         | owner: owner,
           owner_monitor: Process.monitor(owner),
           lifecycle_bound?: true,
           run_state: run_state,
           run_state_monitor: Process.monitor(run_state)
       }}
    else
      {:reply, {:error, :provider_session_unavailable}, state}
    end
  end

  def handle_call(
        {token, {:attach_provider, provider}},
        _from,
        %{token: token, lifecycle_bound?: true} = state
      )
      when is_pid(provider) do
    if Process.alive?(provider) do
      monitor = Process.monitor(provider)
      {:reply, :ok, %{state | providers: Map.put(state.providers, monitor, provider)}}
    else
      {:reply, {:error, :provider_down}, state}
    end
  end

  def handle_call({token, :drain_provider_tasks}, _from, state) when token == state.token do
    {:reply, :ok, drain_provider_tasks_state(state)}
  end

  def handle_call({token, {:close_with_unregistered, close}}, _from, state)
      when token == state.token and (is_function(close, 0) or is_nil(close)) do
    state =
      state
      |> drain_provider_tasks_state()
      |> add_committed_close(close)

    {result, state} = drain(state)
    {:stop, :normal, result, state}
  end

  def handle_call({token, :close}, _from, state) when token == state.token do
    state = drain_provider_tasks_state(state)
    {result, state} = drain(state)
    {:stop, :normal, result, state}
  end

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :provider_session_unavailable}, state}

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{owner_monitor: monitor, owner: owner} = state
      ) do
    state = drain_provider_tasks_state(state)
    {_result, state} = drain(state)
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, run_state, _reason},
        %{run_state_monitor: monitor, run_state: run_state} = state
      ) do
    state = drain_provider_tasks_state(state)
    {:noreply, %{state | run_state: nil, run_state_monitor: nil}}
  end

  def handle_info({:DOWN, monitor, :process, _provider, _reason}, state) do
    {:noreply, %{state | providers: Map.delete(state.providers, monitor)}}
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

  @impl GenServer
  def terminate(_reason, state) do
    state = drain_provider_tasks_state(state)
    {_result, _state} = drain(state)
    :ok
  end

  defp drain_provider_tasks_state(%{providers: providers} = state) do
    Enum.each(providers, fn {_monitor, provider} -> Process.exit(provider, :kill) end)
    drain_provider_monitors(providers)
    %{state | providers: %{}}
  end

  defp drain_provider_monitors(providers) when map_size(providers) == 0, do: :ok

  defp drain_provider_monitors(providers) do
    receive do
      {:DOWN, monitor, :process, _provider, _reason} when is_map_key(providers, monitor) ->
        drain_provider_monitors(Map.delete(providers, monitor))
    end
  end

  defp abort_scope(scope, state) do
    case Map.fetch(state.scopes, scope) do
      {:ok, %{phase: phase}} when phase in [:inactive, :active] ->
        {:ok, remove_scope(scope, state)}

      {:ok, _committed} ->
        {{:error, :provider_cleanup_failed}, state}

      :error ->
        {:ok, state}
    end
  end

  defp add_committed_close(state, close) do
    scope = make_ref()
    entry = %{phase: :committed, close: close}

    %{
      state
      | scopes: Map.put(state.scopes, scope, entry),
        scope_order: [scope | state.scope_order],
        committed: [scope | state.committed]
    }
  end

  defp close_after_session_loss(_session, nil), do: {:error, :provider_cleanup_failed}

  defp close_after_session_loss(session, close) do
    _ =
      BoundedWorker.run(close,
        timeout_ms: session.cleanup_timeout_ms,
        max_heap_words: session.max_heap_words,
        cancel_with_caller: true
      )

    {:error, :provider_cleanup_failed}
  end

  defp drain(state) do
    committed = state.committed
    provisional = Enum.reject(state.scope_order, &(&1 in committed))
    scopes = committed ++ provisional
    state = ensure_cleanup_deadline(state)
    slots = cleanup_slots(scopes, state.scopes)

    {result, state, _remaining_slots} =
      Enum.reduce(scopes, {:ok, state, slots}, fn
        scope, {result, current, remaining_slots} ->
          case Map.fetch(current.scopes, scope) do
            {:ok, entry} ->
              {cleanup, remaining_slots} =
                close_scope(
                  entry,
                  current.cleanup_deadline,
                  current.max_heap_words,
                  remaining_slots
                )

              result = merge_cleanup(result, cleanup)
              {result, remove_scope(scope, current), remaining_slots}

            :error ->
              {result, current, remaining_slots}
          end
      end)

    {normalize_cleanup(result), state}
  end

  defp close_scope(%{phase: :committed, close: nil}, _deadline, _heap_words, remaining_slots),
    do: {:ok, remaining_slots}

  defp close_scope(
         %{phase: :committed, close: close},
         deadline,
         heap_words,
         remaining_slots
       ),
       do: safe_close(close, deadline, heap_words, remaining_slots)

  defp close_scope(_provisional, _deadline, _heap_words, remaining_slots),
    do: {:ok, remaining_slots}

  defp safe_close(close, deadline, heap_words, remaining_slots) do
    remaining_ms = Deadline.remaining(deadline)

    result =
      if remaining_ms > 0 and remaining_slots > 0 do
        timeout_ms = max(div(remaining_ms, remaining_slots), 1)

        case BoundedWorker.run(close,
               timeout_ms: timeout_ms,
               max_heap_words: heap_words,
               cancel_with_caller: true
             ) do
          {:ok, :ok} -> :ok
          _failure -> {:error, :provider_cleanup_failed}
        end
      else
        {:error, :provider_cleanup_failed}
      end

    {result, max(remaining_slots - 1, 0)}
  end

  defp cleanup_slots(scopes, entries) do
    Enum.reduce(scopes, 0, fn scope, count ->
      case Map.fetch(entries, scope) do
        {:ok, %{phase: :committed, close: close}} when is_function(close, 0) ->
          count + 1

        _missing_or_provisional ->
          count
      end
    end)
  end

  defp ensure_cleanup_deadline(%{cleanup_deadline: nil} = state),
    do: %{state | cleanup_deadline: Deadline.new(state.cleanup_timeout_ms)}

  defp ensure_cleanup_deadline(state), do: state

  defp remove_scope(scope, state) do
    case Map.pop(state.scopes, scope) do
      {nil, _scopes} ->
        state

      {_entry, scopes} ->
        %{
          state
          | scopes: scopes,
            scope_order: List.delete(state.scope_order, scope),
            committed: List.delete(state.committed, scope)
        }
    end
  end

  defp registrar_call(registrar, operation, fallback) do
    if ResourceRegistrar.valid?(registrar) do
      call(
        registrar.session,
        {registrar.token, {:registrar, registrar.scope, operation}},
        :infinity,
        fallback
      )
    else
      fallback
    end
  end

  defp call(pid, request, timeout, fallback \\ {:error, :provider_session_unavailable}) do
    GenServer.call(pid, request, timeout)
  catch
    :exit, _reason -> fallback
  end

  defp merge_cleanup(:ok, :ok), do: :ok
  defp merge_cleanup(_left, _right), do: {:error, :provider_cleanup_failed}

  defp normalize_cleanup(:ok), do: :ok
  defp normalize_cleanup(_failure), do: {:error, :provider_cleanup_failed}

  defp payload(session) do
    {
      session.pid,
      session.token,
      session.creator,
      session.cleanup_timeout_ms,
      session.max_heap_words
    }
  end

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end
end
