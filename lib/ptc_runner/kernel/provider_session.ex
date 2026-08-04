defmodule PtcRunner.Kernel.ProviderSession do
  @moduledoc """
  One owner-backed cleanup stack for a command's active provider work.

  A session initially monitors its build creator and owns every acquisition
  scope opened through `PtcRunner.Kernel.ResourceRegistrar`. An active session
  is sealed to one exact prepared operation. After optional application
  admission it anchors that operation's absolute run deadline, then atomically
  claims the operation before provider acquisition, so neither another prepared
  run nor a replay can share its cleanup boundary. Before provider
  callbacks can start, execution binds the session exactly once to its lifecycle
  owner and run state. The session then tracks every provider task itself, so
  owner or run-state death drains live tasks before any provider closer runs.
  Each scope starts provisional, activates immediately before acquisition, and
  is either committed with one provider close operation or aborted. Normal
  close and lifecycle-owner death drain committed scopes in reverse commit
  order, then discard remaining provisional scopes in reverse creation order.
  A local process root monitors its scope's signal owner and synchronously
  registers with the private scope controller before its start operation
  returns. The controller forwards registration into one authoritative cleanup
  owner; terminalization handoff and cleanup address that owner directly and
  remain available if the controller stalls. Scope cleanup runs its closer
  first, then the cleanup owner stops the signal owner so registered roots can
  shut down normally; roots still alive at the bounded cutoff are killed and
  observed. Registration, terminalization handoff, normal cleanup, and
  session-crash cleanup therefore share one serialized root set. An OAuth root with unsettled
  terminal work must close itself to new work and transfer ownership before the
  force-close phase; abnormal session death permits that handoff during the
  cooperative owner-down window.

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
  alias PtcRunner.Kernel.ProviderScopeOwner
  alias PtcRunner.Kernel.ResourceRegistrar

  @enforce_keys [
    :pid,
    :token,
    :creator,
    :operation_identity,
    :run_duration_ms,
    :run_deadline,
    :cleanup_timeout_ms,
    :max_heap_words,
    :attestation
  ]
  @registration_timeout_ms 5_000
  @registration_mutation_reserve_ms 50
  @claim_timeout_ms 5_000
  @claim_reply_grace_ms 100
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @opaque t :: %__MODULE__{
            pid: pid(),
            token: reference(),
            creator: pid(),
            operation_identity: binary() | nil,
            run_duration_ms: pos_integer(),
            run_deadline: Deadline.t() | nil,
            cleanup_timeout_ms: pos_integer(),
            max_heap_words: pos_integer(),
            attestation: binary()
          }

  @spec start(Limits.t()) :: {:ok, t()} | {:error, term()}
  def start(%Limits{} = limits), do: start_session(limits, nil)
  def start(_limits), do: {:error, :invalid_provider_session}

  @doc false
  @spec start_active(Limits.t(), binary()) :: {:ok, t()} | {:error, term()}
  def start_active(%Limits{} = limits, operation_identity) when is_binary(operation_identity),
    do: start_session(limits, operation_identity)

  def start_active(_limits, _operation_identity), do: {:error, :invalid_provider_session}

  defp start_session(limits, operation_identity) do
    if Limits.valid?(limits) do
      creator = self()
      token = make_ref()

      case GenServer.start(__MODULE__, {creator, token, limits, operation_identity}) do
        {:ok, pid} ->
          session = %__MODULE__{
            pid: pid,
            token: token,
            creator: creator,
            operation_identity: operation_identity,
            run_duration_ms: limits.run_duration_ms,
            run_deadline: nil,
            cleanup_timeout_ms: limits.provider_cleanup_timeout_ms,
            max_heap_words: limits.provider_heap_words,
            attestation: <<>>
          }

          {:ok, seal(session)}

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :invalid_provider_session}
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = session),
    do:
      Enum.sort(Map.keys(session)) == @field_keys and is_pid(session.pid) and
        is_reference(session.token) and is_pid(session.creator) and
        (is_nil(session.operation_identity) or is_binary(session.operation_identity)) and
        is_integer(session.run_duration_ms) and session.run_duration_ms > 0 and
        (is_nil(session.run_deadline) or Deadline.valid?(session.run_deadline)) and
        Attestation.valid?(__MODULE__, payload(session), session.attestation)

  def valid?(_session), do: false

  @doc false
  @spec alive?(term()) :: boolean()
  def alive?(%__MODULE__{} = session), do: valid?(session) and Process.alive?(session.pid)
  def alive?(_session), do: false

  @doc false
  @spec compatible_limits?(term(), term()) :: boolean()
  def compatible_limits?(%__MODULE__{} = session, %Limits{} = limits) do
    valid?(session) and Limits.valid?(limits) and
      session.cleanup_timeout_ms == limits.provider_cleanup_timeout_ms and
      session.max_heap_words == limits.provider_heap_words and
      compatible_run_duration?(session, limits)
  end

  def compatible_limits?(_session, _limits), do: false

  @doc false
  @spec begin_run(t()) ::
          {:ok, t()} | {:error, :provider_session_unavailable}
  def begin_run(%__MODULE__{} = session) do
    if valid?(session) and session.creator == self() and
         is_binary(session.operation_identity) and is_nil(session.run_deadline) do
      run_deadline = Deadline.new(session.run_duration_ms)
      operation_deadline = Deadline.new(@claim_timeout_ms)

      result =
        call(
          session.pid,
          {session.token, {:begin_run, run_deadline, operation_deadline}},
          Deadline.remaining(operation_deadline) + @claim_reply_grace_ms,
          {:error, :provider_session_unavailable}
        )

      case result do
        :ok ->
          {:ok, session |> Map.put(:run_deadline, run_deadline) |> seal()}

        {:error, :provider_session_unavailable} = error ->
          abandon_unclaimed(session)
          error
      end
    else
      if valid?(session), do: abandon_unclaimed(session)
      {:error, :provider_session_unavailable}
    end
  end

  def begin_run(_session), do: {:error, :provider_session_unavailable}

  @doc false
  @spec run_deadline(term()) :: Deadline.t() | nil
  def run_deadline(%__MODULE__{} = session) do
    if valid?(session), do: session.run_deadline
  end

  def run_deadline(_session), do: nil

  @doc false
  @spec bound_to_operation?(term(), term()) :: boolean()
  def bound_to_operation?(%__MODULE__{} = session, operation_identity)
      when is_binary(operation_identity) do
    valid?(session) and session.creator == self() and
      session.operation_identity == operation_identity
  end

  def bound_to_operation?(_session, _operation_identity), do: false

  @doc false
  @spec execution_deadline(term()) :: {:ok, Deadline.t() | nil} | :error
  def execution_deadline(%__MODULE__{} = session) do
    cond do
      not valid?(session) ->
        :error

      is_nil(session.operation_identity) and is_nil(session.run_deadline) ->
        {:ok, nil}

      is_binary(session.operation_identity) and Deadline.valid?(session.run_deadline) ->
        {:ok, session.run_deadline}

      true ->
        :error
    end
  end

  def execution_deadline(_session), do: :error

  @doc false
  @spec worker_cancel_target(term()) :: pid() | nil
  def worker_cancel_target(%__MODULE__{} = session) do
    if valid?(session), do: session.pid
  end

  def worker_cancel_target(_session), do: nil

  @doc false
  @spec cleanup_timeout(term()) :: pos_integer() | nil
  def cleanup_timeout(%__MODULE__{} = session) do
    if valid?(session), do: session.cleanup_timeout_ms
  end

  def cleanup_timeout(_session), do: nil

  @doc false
  @spec claim_operation(t(), Limits.t(), binary()) ::
          :ok
          | {:error, :operation_claimed | :operation_mismatch | :provider_session_unavailable}
  def claim_operation(%__MODULE__{} = session, %Limits{} = limits, identity)
      when is_binary(identity) do
    if valid?(session) and Limits.valid?(limits) and Deadline.valid?(session.run_deadline) do
      deadline = Deadline.new(@claim_timeout_ms)

      result =
        try do
          GenServer.call(
            session.pid,
            {session.token,
             {:claim_operation, identity, limits.provider_cleanup_timeout_ms,
              limits.provider_heap_words, limits.run_duration_ms, session.run_deadline, deadline}},
            Deadline.remaining(deadline) + @claim_reply_grace_ms
          )
        catch
          :exit, _reason -> {:error, :provider_session_unavailable}
        end

      case result do
        {:error, :provider_session_unavailable} = error ->
          # The claim may have committed before its reply became unavailable.
          # Preserve that session, but queue cleanup behind this request when
          # the operation was never claimed.
          GenServer.cast(session.pid, {session.token, :close_if_unclaimed})
          error

        result ->
          result
      end
    else
      if valid?(session), do: GenServer.cast(session.pid, {session.token, :close_if_unclaimed})
      {:error, :provider_session_unavailable}
    end
  end

  def claim_operation(_session, _limits, _identity),
    do: {:error, :provider_session_unavailable}

  @spec open_registrar(t()) ::
          {:ok, ResourceRegistrar.t()} | {:error, :provider_session_unavailable}
  def open_registrar(%__MODULE__{} = session) do
    if valid?(session) and session.creator == self() do
      case call(session.pid, {session.token, :open_registrar}, 5_000) do
        {:ok, scope, scope_controller, root_owner, cleanup_owner} ->
          {:ok,
           ResourceRegistrar.new(
             session.pid,
             session.token,
             scope,
             scope_controller,
             root_owner,
             cleanup_owner
           )}

        _failure ->
          {:error, :provider_session_unavailable}
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

  @doc false
  def register_root(%ResourceRegistrar{} = registrar),
    do: register_root(registrar, @registration_timeout_ms)

  @doc false
  def register_root(%ResourceRegistrar{} = registrar, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    if ResourceRegistrar.valid?(registrar) do
      response_deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

      mutation_deadline_ms =
        response_deadline_ms - min(@registration_mutation_reserve_ms, div(timeout_ms, 2))

      call(
        registrar.session,
        {registrar.token,
         {:registrar, registrar.scope,
          {:register_root, mutation_deadline_ms, response_deadline_ms}}},
        timeout_ms,
        {:error, :resource_registrar_unavailable}
      )
    else
      {:error, :resource_registrar_unavailable}
    end
  end

  def register_root(_registrar, _timeout_ms), do: {:error, :resource_registrar_unavailable}

  @doc false
  def handoff_root(%ResourceRegistrar{} = registrar, root) when is_pid(root) do
    if ResourceRegistrar.valid?(registrar) do
      case ProviderScopeOwner.handoff(registrar.cleanup_owner, registrar.session, root) do
        :ok ->
          :ok

        {:error, _reason} ->
          {:error, :resource_registrar_unavailable}
      end
    else
      {:error, :resource_registrar_unavailable}
    end
  end

  @impl true
  def init({creator, token, %Limits{} = limits, operation_identity}) do
    {:ok,
     %{
       owner: creator,
       owner_monitor: Process.monitor(creator),
       token: token,
       operation_identity: operation_identity,
       run_deadline: nil,
       operation_claimed?: false,
       run_duration_ms: limits.run_duration_ms,
       cleanup_timeout_ms: limits.provider_cleanup_timeout_ms,
       cleanup_deadline: nil,
       max_heap_words: limits.provider_heap_words,
       lifecycle_bound?: false,
       run_state: nil,
       run_state_monitor: nil,
       providers: %{},
       pending_registrations: %{},
       scopes: %{},
       scope_order: [],
       committed: []
     }}
  end

  def handle_call(
        {token, {:begin_run, run_deadline, operation_deadline}},
        {owner, _tag},
        %{
          token: token,
          owner: owner,
          operation_identity: operation_identity,
          run_deadline: nil,
          operation_claimed?: false
        } = state
      )
      when is_binary(operation_identity) do
    if Deadline.live?(run_deadline) and Deadline.live?(operation_deadline) do
      {:reply, :ok, %{state | run_deadline: run_deadline}}
    else
      {:stop, :normal, {:error, :provider_session_unavailable}, state}
    end
  end

  def handle_call(
        {token,
         {:claim_operation, identity, cleanup_timeout_ms, max_heap_words, run_duration_ms,
          run_deadline, deadline}},
        {owner, _tag},
        %{
          token: token,
          owner: owner,
          operation_identity: identity,
          run_deadline: run_deadline,
          run_duration_ms: run_duration_ms,
          cleanup_timeout_ms: cleanup_timeout_ms,
          max_heap_words: max_heap_words,
          operation_claimed?: false
        } = state
      ) do
    if Deadline.live?(run_deadline) and Deadline.live?(deadline) do
      {:reply, :ok, %{state | operation_claimed?: true}}
    else
      {:stop, :normal, {:error, :provider_session_unavailable}, state}
    end
  end

  def handle_call(
        {token,
         {:claim_operation, _identity, _cleanup_timeout_ms, _max_heap_words, _run_duration_ms,
          _run_deadline, _deadline}},
        _from,
        %{token: token, operation_claimed?: true} = state
      ) do
    {:reply, {:error, :operation_claimed}, state}
  end

  def handle_call(
        {token,
         {:claim_operation, _identity, _cleanup_timeout_ms, _max_heap_words, _run_duration_ms,
          run_deadline, deadline}},
        {owner, _tag},
        %{token: token, owner: owner, operation_claimed?: false} = state
      ) do
    if Deadline.live?(run_deadline) and Deadline.live?(deadline) do
      {:reply, {:error, :operation_mismatch}, state}
    else
      {:stop, :normal, {:error, :provider_session_unavailable}, state}
    end
  end

  @impl true
  def handle_call({token, :open_registrar}, {creator, _tag}, state)
      when token == state.token and creator == state.owner do
    scope = make_ref()

    case ProviderScopeOwner.start(self(), state.cleanup_timeout_ms) do
      {:ok, {scope_controller, root_owner, scope_reaper}} ->
        entry = %{
          phase: :inactive,
          close: nil,
          roots_registered?: false,
          scope_controller: scope_controller,
          root_owner: root_owner,
          scope_reaper: scope_reaper
        }

        {:reply, {:ok, scope, scope_controller, root_owner, scope_reaper},
         %{
           state
           | scopes: Map.put(state.scopes, scope, entry),
             scope_order: [scope | state.scope_order]
         }}

      {:error, :provider_scope_unavailable} ->
        {:reply, {:error, :provider_session_unavailable}, state}
    end
  end

  def handle_call({token, {:registrar, scope, :activate}}, _from, state)
      when token == state.token do
    case Map.fetch(state.scopes, scope) do
      {:ok, %{phase: :inactive, scope_controller: scope_controller} = entry}
      when is_pid(scope_controller) ->
        if Process.alive?(scope_controller) do
          {:reply, :ok, put_in(state.scopes[scope], %{entry | phase: :active})}
        else
          {:reply, {:error, :resource_registrar_unavailable}, state}
        end

      _missing_or_closed ->
        {:reply, {:error, :resource_registrar_unavailable}, state}
    end
  end

  def handle_call({token, {:registrar, scope, {:commit, close}}}, _from, state)
      when token == state.token do
    case Map.fetch(state.scopes, scope) do
      {:ok, %{phase: :active, scope_controller: scope_controller} = entry}
      when (is_function(close, 0) or is_nil(close)) and is_pid(scope_controller) ->
        if Process.alive?(scope_controller) do
          entry = %{entry | phase: :committed, close: close}

          {:reply, :ok,
           %{put_in(state.scopes[scope], entry) | committed: [scope | state.committed]}}
        else
          {:reply, {:error, :resource_registrar_unavailable}, state}
        end

      _missing_or_closed ->
        {:reply, {:error, :resource_registrar_unavailable}, state}
    end
  end

  def handle_call({token, {:registrar, scope, :abort}}, _from, state)
      when token == state.token do
    state = reject_pending_registrations(state, scope)
    {result, state} = abort_scope(scope, state)
    {:reply, result, state}
  end

  def handle_call(
        {token,
         {:registrar, scope, {:register_root, mutation_deadline_ms, response_deadline_ms}}},
        {root, _tag} = from,
        state
      )
      when token == state.token and is_pid(root) and node(root) == node() and
             is_integer(mutation_deadline_ms) and is_integer(response_deadline_ms) do
    case Map.fetch(state.scopes, scope) do
      {:ok, %{phase: :active, scope_controller: scope_controller}} ->
        if before_deadline?(mutation_deadline_ms) and Process.alive?(scope_controller) and
             pending_registration_count(state.pending_registrations, scope) <
               ProviderScopeOwner.max_roots() do
          request_ref = make_ref()

          :ok =
            ProviderScopeOwner.register(
              scope_controller,
              self(),
              root,
              self(),
              request_ref,
              mutation_deadline_ms
            )

          timer =
            Process.send_after(
              self(),
              {__MODULE__, :registration_timeout, request_ref},
              remaining(response_deadline_ms)
            )

          pending = %{
            from: from,
            scope: scope,
            timer: timer,
            mutation_deadline_ms: mutation_deadline_ms,
            response_deadline_ms: response_deadline_ms
          }

          {:noreply,
           %{
             state
             | pending_registrations: Map.put(state.pending_registrations, request_ref, pending)
           }}
        else
          {:reply, {:error, :resource_registrar_unavailable}, state}
        end

      _missing_or_closed ->
        {:reply, {:error, :resource_registrar_unavailable}, state}
    end
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
      |> reject_pending_registrations()
      |> drain_provider_tasks_state()
      |> add_committed_close(close)

    {result, state} = drain(state)
    {:stop, :normal, result, state}
  end

  def handle_call({token, :close}, _from, state) when token == state.token do
    state = state |> reject_pending_registrations() |> drain_provider_tasks_state()
    {result, state} = drain(state)
    {:stop, :normal, result, state}
  end

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :provider_session_unavailable}, state}

  @impl true
  def handle_cast(
        {token, :close_if_unclaimed},
        %{token: token, operation_claimed?: false} = state
      ) do
    {:stop, :normal, state}
  end

  def handle_cast({token, :close_if_unclaimed}, %{token: token} = state),
    do: {:noreply, state}

  def handle_cast(_request, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{owner_monitor: monitor, owner: owner} = state
      ) do
    state = state |> reject_pending_registrations() |> drain_provider_tasks_state()
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

  def handle_info(
        {ProviderScopeOwner, :registration_result, request_ref, result},
        state
      ) do
    case Map.pop(state.pending_registrations, request_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from, scope: scope, timer: timer}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, normalize_registration_result(result))

        state = %{state | pending_registrations: pending}

        state =
          if result == :ok do
            update_in(state.scopes[scope], &Map.put(&1, :roots_registered?, true))
          else
            state
          end

        {:noreply, state}
    end
  end

  def handle_info({__MODULE__, :registration_timeout, request_ref}, state) do
    case Map.pop(state.pending_registrations, request_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, :resource_registrar_unavailable})
        {:noreply, %{state | pending_registrations: pending}}
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

  @impl GenServer
  def terminate(_reason, state) do
    state = state |> reject_pending_registrations() |> drain_provider_tasks_state()
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
      {:ok, %{phase: phase} = entry} when phase in [:inactive, :active] ->
        cleanup = close_roots(entry, Deadline.new(state.cleanup_timeout_ms))

        {:ok, remove_scope(scope, state)}
        |> merge_abort_cleanup(cleanup)

      {:ok, _committed} ->
        {{:error, :provider_cleanup_failed}, state}

      :error ->
        {:ok, state}
    end
  end

  defp add_committed_close(state, close) do
    scope = make_ref()

    entry = %{
      phase: :committed,
      close: close,
      roots_registered?: false,
      scope_controller: nil,
      root_owner: nil,
      scope_reaper: nil
    }

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

              {root_cleanup, remaining_slots} =
                close_roots(entry, current.cleanup_deadline, remaining_slots)

              result = result |> merge_cleanup(cleanup) |> merge_cleanup(root_cleanup)
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
        {:ok, entry} ->
          count +
            if(entry.phase == :committed and is_function(entry.close, 0), do: 1, else: 0) +
            if(entry.roots_registered?, do: 1, else: 0)

        :error ->
          count
      end
    end)
  end

  defp ensure_cleanup_deadline(%{cleanup_deadline: nil} = state),
    do: %{state | cleanup_deadline: Deadline.new(state.cleanup_timeout_ms)}

  defp ensure_cleanup_deadline(state), do: state

  defp close_roots(entry, deadline) do
    root_slots = if entry.roots_registered?, do: 1, else: 0
    {result, _remaining_slots} = close_roots(entry, deadline, root_slots)
    result
  end

  defp close_roots(%{scope_controller: nil}, _deadline, remaining_slots),
    do: {:ok, remaining_slots}

  defp close_roots(entry, deadline, remaining_slots) do
    remaining_ms = Deadline.remaining(deadline)

    {timeout_ms, next_slots} =
      if entry.roots_registered? do
        timeout_ms = if remaining_slots > 0, do: div(remaining_ms, remaining_slots), else: 0
        {timeout_ms, max(remaining_slots - 1, 0)}
      else
        timeout_ms =
          if remaining_slots > 0,
            do: div(remaining_ms, remaining_slots + 1),
            else: remaining_ms

        {timeout_ms, remaining_slots}
      end

    result = close_roots_with_timeout(entry, timeout_ms)

    {result, next_slots}
  end

  defp close_roots_with_timeout(entry, timeout_ms) when timeout_ms <= 0 do
    ProviderScopeOwner.stop(entry.scope_controller, entry.scope_reaper, self(), 0)
  end

  defp close_roots_with_timeout(entry, timeout_ms) do
    ProviderScopeOwner.stop(entry.scope_controller, entry.scope_reaper, self(), timeout_ms)
  end

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

  defp reject_pending_registrations(state, scope \\ :all) do
    {rejected, retained} =
      Enum.split_with(state.pending_registrations, fn {_request_ref, pending} ->
        scope == :all or pending.scope == scope
      end)

    Enum.each(rejected, fn {_request_ref, %{from: from, timer: timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :resource_registrar_unavailable})
    end)

    %{state | pending_registrations: Map.new(retained)}
  end

  defp pending_registration_count(pending_registrations, scope) do
    Enum.count(pending_registrations, fn {_request_ref, pending} ->
      pending.scope == scope
    end)
  end

  defp before_deadline?(deadline_ms),
    do: System.monotonic_time(:millisecond) < deadline_ms

  defp remaining(deadline_ms),
    do: max(deadline_ms - System.monotonic_time(:millisecond), 0)

  defp normalize_registration_result(:ok), do: :ok

  defp normalize_registration_result(_failure),
    do: {:error, :resource_registrar_unavailable}

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

  defp merge_abort_cleanup({:ok, state}, :ok), do: {:ok, state}

  defp merge_abort_cleanup({:ok, state}, _failure),
    do: {{:error, :provider_cleanup_failed}, state}

  defp normalize_cleanup(:ok), do: :ok
  defp normalize_cleanup(_failure), do: {:error, :provider_cleanup_failed}

  defp payload(session) do
    {
      session.pid,
      session.token,
      session.creator,
      session.operation_identity,
      session.run_duration_ms,
      session.run_deadline,
      session.cleanup_timeout_ms,
      session.max_heap_words
    }
  end

  defp seal(session),
    do: %{session | attestation: Attestation.attest(__MODULE__, payload(session))}

  defp abandon_unclaimed(session),
    do: GenServer.cast(session.pid, {session.token, :close_if_unclaimed})

  defp compatible_run_duration?(%__MODULE__{operation_identity: nil}, _limits), do: true

  defp compatible_run_duration?(%__MODULE__{run_duration_ms: run_duration_ms}, limits),
    do: run_duration_ms == limits.run_duration_ms

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end
end
