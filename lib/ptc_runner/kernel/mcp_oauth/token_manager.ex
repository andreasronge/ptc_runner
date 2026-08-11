defmodule PtcRunner.Kernel.MCPOAuth.TokenManager do
  @moduledoc """
  Principal-scoped bearer-token owner for one installed MCP authority.

  The owner serializes only refresh leadership and lifecycle transitions.
  Store, discovery, credential-resolution, and network work runs outside the
  owner. Before returning a header, the admitted caller reloads the current
  store generation and takes a dispatch admission for that exact generation.
  Callers must release the returned admission after the HTTP attempt.

  A `401` marks only the generation actually sent. A `403` requirement is
  persisted only after the caller supplies one strictly parsed Bearer
  challenge. The manager atomically installs the corresponding runtime-shared
  local fence and starts a bounded non-owner persistence worker before
  replying, so caller death, manager replacement, or a failed durable
  transition cannot reissue the rejected authority. A strictly newer
  sufficient grant clears that fallback fence. Shutdown drains these bounded
  persistence workers before discarding local state. A failed persistence is
  retained and retried on close; close fails without stopping the manager if
  that retry also fails. Neither response is replayed automatically.
  Session-owner death adopts unsettled persistence through the bounded cleanup
  owner before the registrar's cooperative shutdown window ends.
  """

  use GenServer

  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.BearerChallenge
  alias PtcRunner.Kernel.MCPOAuth.Binding
  alias PtcRunner.Kernel.MCPOAuth.Context
  alias PtcRunner.Kernel.MCPOAuth.Discovery
  alias PtcRunner.Kernel.MCPOAuth.LocalFences
  alias PtcRunner.Kernel.MCPOAuth.ManagerCleanup
  alias PtcRunner.Kernel.MCPOAuth.Scope
  alias PtcRunner.Kernel.MCPOAuth.Store
  alias PtcRunner.Kernel.MCPOAuth.TokenClient
  alias PtcRunner.Kernel.ResourceRegistrar

  @response_transition_timeout_ms 5_000
  @close_timeout_ms @response_transition_timeout_ms + 1_000
  @competing_refresh_poll_ms 10

  @enforce_keys [:pid, :resource]
  defstruct @enforce_keys

  @type t :: %__MODULE__{pid: pid(), resource: binary()}
  @type issued :: %{
          required(:header) => {binary(), binary()},
          required(:generation) => non_neg_integer(),
          required(:admission) => term(),
          required(:egress) => map(),
          required(:release) => (integer() -> :ok | {:error, atom()})
        }

  @spec start(keyword()) :: {:ok, t()} | {:error, atom()}
  def start(opts) when is_list(opts) do
    with %Context{} = context <- Keyword.get(opts, :context),
         %Authority{} = authority <- Keyword.get(opts, :authority),
         authority_epoch when not is_nil(authority_epoch) <- Keyword.get(opts, :authority_epoch),
         owner when is_pid(owner) <- Keyword.get(opts, :owner),
         key = Context.grant_key(context, authority, authority_epoch),
         {:ok, pid} <-
           start_owner(%{
             owner: owner,
             resource_registrar: Keyword.get(opts, :resource_registrar),
             context: context,
             authority: authority,
             key: key,
             request: Keyword.get(opts, :request),
             resolver: Keyword.get(opts, :resolver)
           }) do
      {:ok, %__MODULE__{pid: pid, resource: authority.resource}}
    else
      {:error, :resource_registrar_unavailable} = error -> error
      _invalid -> {:error, :invalid_token_manager}
    end
  end

  def start(_opts), do: {:error, :invalid_token_manager}

  defp start_owner(%{context: context} = config) do
    case GenServer.start(__MODULE__, config) do
      {:ok, pid} = success ->
        case Store.register_manager(context.store, pid) do
          :ok ->
            success

          {:error, _reason} ->
            Process.exit(pid, :kill)
            {:error, :invalid_token_manager}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec authorization_header(t(), integer(), pid()) :: {:ok, issued()} | {:error, atom()}
  def authorization_header(manager, deadline_ms, admission_owner \\ self())

  def authorization_header(%__MODULE__{pid: pid}, deadline_ms, admission_owner)
      when is_integer(deadline_ms) and is_pid(admission_owner) do
    with {:ok, config} <- owner_call(pid, :config, deadline_ms),
         {:ok, grant} <- usable_grant(pid, config, deadline_ms),
         :ok <-
           owner_call(
             pid,
             {:admit_grant, grant.generation, grant.granted_scopes},
             deadline_ms
           ),
         :ok <-
           LocalFences.admit(
             config.local_fence_identity,
             grant.generation,
             grant.granted_scopes
           ),
         {:ok, admission} <-
           Store.admit_mcp(
             config.context.store,
             config.key,
             grant.generation,
             admission_owner,
             remaining(deadline_ms),
             Deadline.from_expires_at(deadline_ms)
           ) do
      {:ok,
       %{
         header: {"authorization", "Bearer " <> grant.access_token},
         generation: grant.generation,
         admission: admission,
         egress: %{authority: config.authority, resolver: config.resolver},
         release: release_callback(config.context.store, admission)
       }}
    else
      {:error, reason} -> {:error, close_reason(reason)}
    end
  end

  def authorization_header(_manager, _deadline_ms, _admission_owner),
    do: {:error, :mcp_authorization_required}

  @spec release(t(), term(), integer()) :: :ok | {:error, atom()}
  def release(%__MODULE__{pid: pid}, admission, deadline_ms) do
    case owner_call(pid, :config, deadline_ms) do
      {:ok, config} ->
        Store.release_mcp(
          config.context.store,
          admission,
          Deadline.from_expires_at(deadline_ms)
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec reject(t(), non_neg_integer(), integer()) :: :ok | {:error, atom()}
  def reject(%__MODULE__{pid: pid}, generation, _request_deadline_ms) do
    deadline_ms = response_transition_deadline()

    owner_call(
      pid,
      {:reject_generation, generation, deadline_ms},
      deadline_ms
    )
  end

  @spec require_scopes(t(), non_neg_integer(), [binary()], integer()) ::
          :ok | {:error, atom()}
  def require_scopes(
        %__MODULE__{pid: pid},
        generation,
        authenticate_headers,
        _request_deadline_ms
      )
      when is_list(authenticate_headers) do
    with {:ok, params} <- BearerChallenge.parse(authenticate_headers),
         true <- is_map(params) and Map.get(params, "error") == "insufficient_scope",
         scope when is_binary(scope) <- Map.get(params, "scope"),
         {:ok, scopes} <- Scope.parse_string(scope),
         true <- MapSet.size(scopes) > 0 do
      deadline_ms = response_transition_deadline()

      case owner_call(
             pid,
             {:block_authorization, generation, scopes, deadline_ms},
             deadline_ms
           ) do
        :ok -> :ok
        {:error, :authorization_required} -> {:error, :mcp_authorization_required}
        {:error, _reason} = error -> error
      end
    else
      _invalid -> {:error, :invalid_scope_challenge}
    end
  end

  def require_scopes(_manager, _generation, _headers, _deadline_ms),
    do: {:error, :invalid_scope_challenge}

  @spec close(t()) :: :ok | {:error, :persistence_failed | :timeout}
  def close(%__MODULE__{} = manager), do: close(manager, @close_timeout_ms)

  @doc false
  @spec close(t(), pos_integer()) :: :ok | {:error, :persistence_failed | :timeout}
  def close(%__MODULE__{pid: pid}, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(pid, :close, min(timeout_ms, @close_timeout_ms))
  catch
    :exit, {:timeout, _detail} -> {:error, :timeout}
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(config) do
    local_fence_identity = LocalFences.identity(config.context.store, config.key)
    owner_ref = Process.monitor(config.owner)

    case ResourceRegistrar.register_root(config.resource_registrar) do
      :ok ->
        {:ok,
         %{
           owner_ref: owner_ref,
           resource_registrar: config.resource_registrar,
           config:
             config
             |> Map.drop([:owner, :resource_registrar])
             |> Map.put(:local_fence_identity, local_fence_identity),
           refresh: nil,
           rejected_generations: MapSet.new(),
           local_requirement: nil,
           response_persistences: %{},
           owner_down: false,
           closing: nil
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:close, _from, %{closing: nil, response_persistences: persistences} = state)
      when map_size(persistences) == 0,
      do: {:stop, :normal, :ok, state}

  def handle_call(:close, from, %{closing: nil} = state) do
    state
    |> Map.put(:closing, [from])
    |> retry_failed_persistences()
    |> close_or_continue()
  end

  def handle_call(:close, from, %{closing: waiters} = state),
    do: {:noreply, %{state | closing: [from | waiters]}}

  def handle_call(_message, _from, %{owner_down: true} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call(_message, _from, %{closing: waiters} = state) when is_list(waiters),
    do: {:reply, {:error, :closed}, state}

  def handle_call(:config, _from, state),
    do: {:reply, {:ok, state.config}, state}

  def handle_call({:admit_grant, generation, granted_scopes}, _from, state) do
    rejected_generations =
      MapSet.filter(state.rejected_generations, &(&1 >= generation))

    state = %{state | rejected_generations: rejected_generations}

    cond do
      MapSet.member?(rejected_generations, generation) ->
        {:reply, {:error, :authorization_required}, state}

      local_requirement_satisfied?(state.local_requirement, generation, granted_scopes) ->
        {:reply, :ok, %{state | local_requirement: nil}}

      is_map(state.local_requirement) ->
        {:reply, {:error, :authorization_required}, state}

      true ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:reject_generation, generation, deadline_ms}, from, state) do
    state = update_in(state.rejected_generations, &MapSet.put(&1, generation))

    start_response_persistence(
      state,
      from,
      deadline_ms,
      {:rejected_generation, generation},
      fn persistence_deadline_ms ->
        persist_rejection(state.config, generation, persistence_deadline_ms)
      end
    )
  end

  def handle_call(
        {:block_authorization, generation, scopes, deadline_ms},
        from,
        state
      ) do
    if match?(%MapSet{}, scopes) and MapSet.size(scopes) > 0 and
         Scope.subset?(scopes, state.config.authority.scope_ceiling) do
      requirement =
        case state.local_requirement do
          %{source_generation: previous_generation, scopes: previous_scopes} ->
            %{
              source_generation: max(generation, previous_generation),
              scopes: MapSet.union(scopes, previous_scopes)
            }

          nil ->
            %{source_generation: generation, scopes: scopes}
        end

      config = state.config

      state = Map.put(state, :local_requirement, requirement)

      start_response_persistence(
        state,
        from,
        deadline_ms,
        {:scope_requirement, generation, scopes},
        fn persistence_deadline_ms ->
          persist_scope_requirement(
            config,
            generation,
            scopes,
            persistence_deadline_ms
          )
        end
      )
    else
      {:reply, {:error, :authorization_required}, state}
    end
  end

  def handle_call({:reserve_refresh, generation}, from, %{refresh: nil} = state) do
    caller = elem(from, 0)
    ref = Process.monitor(caller)
    refresh = %{generation: generation, leader: caller, leader_ref: ref, waiters: []}
    {:reply, :leader, %{state | refresh: refresh}}
  end

  def handle_call(
        {:reserve_refresh, generation},
        from,
        %{refresh: %{generation: generation} = refresh} = state
      ) do
    {:noreply, put_in(state.refresh.waiters, [from | refresh.waiters])}
  end

  def handle_call({:reserve_refresh, _generation}, _from, state),
    do: {:reply, :retry, state}

  def handle_call({:finish_refresh, generation}, {caller, _tag}, state) do
    case state.refresh do
      %{generation: ^generation, leader: ^caller} = refresh ->
        Process.demonitor(refresh.leader_ref, [:flush])
        Enum.each(refresh.waiters, &GenServer.reply(&1, :retry))
        {:reply, :ok, %{state | refresh: nil}}

      _stale ->
        {:reply, :ok, state}
    end
  end

  def handle_call(_message, _from, state),
    do: {:reply, {:error, :closed}, state}

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    maybe_adopt_unsettled(state)

    state
    |> Map.put(:owner_down, true)
    |> Map.update!(:closing, &(&1 || []))
    |> retry_failed_persistences()
    |> close_or_continue()
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{refresh: %{leader_ref: ref} = refresh} = state
      ) do
    Enum.each(refresh.waiters, &GenServer.reply(&1, :retry))
    {:noreply, %{state | refresh: nil}}
  end

  def handle_info({:response_persistence_finished, operation_ref, result}, state) do
    case Map.fetch(state.response_persistences, operation_ref) do
      :error ->
        {:noreply, state}

      {:ok, persistence} ->
        finish_response_persistence(state, operation_ref, persistence, result)
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Enum.find(state.response_persistences, fn
           {_operation_ref, %{monitor_ref: ^monitor_ref}} -> true
           _persistence -> false
         end) do
      {operation_ref, persistence} ->
        finish_response_persistence(
          state,
          operation_ref,
          persistence,
          {:error, :store_error}
        )

      nil ->
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

  defp usable_grant(pid, config, deadline_ms) do
    with {:ok, grant} <-
           Store.load_grant(
             config.context.store,
             config.key,
             Deadline.from_expires_at(deadline_ms)
           ) do
      cond do
        usable_without_refresh?(grant, config.authority) ->
          {:ok, grant}

        refreshable?(grant) ->
          coordinate_refresh(pid, config, grant, deadline_ms)

        true ->
          {:error, :mcp_authorization_required}
      end
    end
  end

  defp coordinate_refresh(pid, config, grant, deadline_ms) do
    case owner_call(pid, {:reserve_refresh, grant.generation}, deadline_ms) do
      :leader ->
        try do
          refresh(config, grant, deadline_ms)
        after
          _ = owner_call(pid, {:finish_refresh, grant.generation}, deadline_ms)
        end

      :retry ->
        usable_grant(pid, config, deadline_ms)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refresh(config, grant, deadline_ms) do
    case Store.acquire_mutation(
           config.context.store,
           config.key,
           :refresh,
           remaining(deadline_ms),
           Deadline.from_expires_at(deadline_ms)
         ) do
      {:ok, lease} ->
        if lease.starting_generation == grant.generation do
          refresh_with_lease(config, grant, lease, deadline_ms)
        else
          fail_before_refresh_dispatch(config, lease, deadline_ms)
          retry_after_competing_refresh(config, deadline_ms)
        end

      {:error, reason} when reason in [:mutation_busy, :mutation_indeterminate] ->
        retry_after_competing_refresh(config, deadline_ms)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp refresh_with_lease(config, grant, lease, deadline_ms) do
    with {:ok, freshness_anchor} <-
           Store.time_anchor(
             config.context.store,
             Deadline.from_expires_at(deadline_ms)
           ),
         {:ok, binding} <-
           Discovery.discover(
             config.authority,
             discovery_options(config, grant, deadline_ms)
           ),
         binding = Map.put(binding, :freshness_anchor, freshness_anchor),
         true <- binding.refresh_authorized,
         true <- compatible_refresh_binding?(grant, binding),
         {:ok, anchor} <-
           Store.time_anchor(
             config.context.store,
             Deadline.from_expires_at(deadline_ms)
           ) do
      result =
        TokenClient.refresh(
          config.authority,
          binding,
          grant,
          token_options(config, binding, lease, deadline_ms)
        )

      commit_refresh(config, grant, binding, lease, anchor, result, deadline_ms)
    else
      {:error, reason} ->
        fail_before_refresh_dispatch(config, lease, deadline_ms)
        {:error, reason}

      false ->
        fail_before_refresh_dispatch(config, lease, deadline_ms)
        {:error, :mcp_authorization_required}
    end
  end

  defp commit_refresh(config, old, binding, lease, anchor, {:ok, refreshed}, deadline_ms) do
    case refresh_token(config.authority, old, refreshed) do
      {:ok, refresh_token} ->
        stored =
          refreshed
          |> Map.delete(:ttl_ms)
          |> Map.put(:refresh_token, refresh_token)
          |> Map.put(:requested_scopes, old.requested_scopes)
          |> Map.put(:metadata_binding, Binding.identity(binding))
          |> Map.put(:metadata_revision, Map.get(old, :metadata_revision, 0) + 1)
          |> Map.put(:redirect_uri, Map.get(old, :redirect_uri))

        case Store.commit_grant(
               config.context.store,
               config.key,
               lease.fence,
               stored,
               refreshed.ttl_ms,
               anchor,
               Deadline.from_expires_at(deadline_ms)
             ) do
          {:ok, _grant} = success ->
            success

          {:error, _reason} ->
            _ =
              Store.fail_mutation(
                config.context.store,
                config.key,
                lease.fence,
                :possibly_dispatched,
                Deadline.new(max(remaining(deadline_ms), 1))
              )

            {:error, :mcp_authorization_required}
        end

      {:error, :unsafe_refresh_rotation} ->
        _ =
          Store.fail_mutation(
            config.context.store,
            config.key,
            lease.fence,
            :possibly_dispatched,
            Deadline.new(max(remaining(deadline_ms), 1))
          )

        {:error, :mcp_authorization_required}
    end
  end

  defp commit_refresh(
         config,
         _old,
         _binding,
         lease,
         _anchor,
         {:error, reason, provenance},
         deadline_ms
       ) do
    outcome =
      cond do
        reason == :invalid_grant -> :invalid_grant
        provenance == :not_dispatched -> :not_dispatched
        true -> :possibly_dispatched
      end

    _ =
      Store.fail_mutation(
        config.context.store,
        config.key,
        lease.fence,
        outcome,
        Deadline.new(max(remaining(deadline_ms), 1))
      )

    {:error, close_reason(reason)}
  end

  defp retry_after_competing_refresh(config, deadline_ms) do
    case Store.load_grant(
           config.context.store,
           config.key,
           Deadline.from_expires_at(deadline_ms)
         ) do
      {:ok, grant} ->
        cond do
          usable_without_refresh?(grant, config.authority) ->
            {:ok, grant}

          refreshable?(grant) and deadline_ms > System.monotonic_time(:millisecond) ->
            wait_for_competing_refresh(deadline_ms)
            refresh(config, grant, deadline_ms)

          true ->
            {:error, :mcp_authorization_required}
        end

      {:error, _reason} ->
        {:error, :mcp_authorization_required}
    end
  end

  defp wait_for_competing_refresh(deadline_ms) do
    wait_ms =
      min(
        @competing_refresh_poll_ms,
        max(deadline_ms - System.monotonic_time(:millisecond), 0)
      )

    receive do
    after
      wait_ms -> :ok
    end
  end

  defp refresh_token(%Authority{client: %{token_endpoint_auth_method: :none}}, old, refreshed) do
    new = Map.get(refreshed, :refresh_token)

    if is_binary(new) and new != old.refresh_token,
      do: {:ok, new},
      else: {:error, :unsafe_refresh_rotation}
  end

  defp refresh_token(
         %Authority{client: %{token_endpoint_auth_method: :client_secret_basic}},
         old,
         refreshed
       ),
       do: {:ok, Map.get(refreshed, :refresh_token) || old.refresh_token}

  defp usable_without_refresh?(
         %{status: :active, access_token: token, remaining_ttl_ms: ttl} = grant,
         authority
       )
       when is_binary(token) and is_integer(ttl),
       do: ttl > if(refreshable?(grant), do: refresh_skew(authority), else: 0)

  defp usable_without_refresh?(_grant, _authority), do: false

  defp refreshable?(%{
         status: :active,
         refresh_authorized: true,
         refresh_token: refresh_token
       }),
       do: is_binary(refresh_token)

  defp refreshable?(_grant), do: false

  defp refresh_skew(authority),
    do: min(30_000, max(div(authority.unknown_expiry_ttl_ms, 10), 1_000))

  defp compatible_refresh_binding?(grant, binding) do
    Map.get(grant, :metadata_binding) == Binding.identity(binding)
  end

  defp discovery_options(config, grant, deadline_ms) do
    [
      request: config.request,
      resolver: config.resolver,
      redirect_uri: Map.get(grant, :redirect_uri),
      deadline_ms: deadline_ms
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp token_options(config, binding, lease, deadline_ms) do
    before_dispatch = fn ->
      Store.begin_mutation_dispatch(
        config.context.store,
        config.key,
        lease.fence,
        binding,
        Deadline.from_expires_at(deadline_ms)
      )
    end

    [
      request: config.request,
      resolver: config.resolver,
      credential_resolver: config.context.credential_resolver,
      deadline_ms: deadline_ms,
      before_dispatch: before_dispatch
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp fail_before_refresh_dispatch(config, lease, deadline_ms) do
    _ =
      Store.fail_mutation(
        config.context.store,
        config.key,
        lease.fence,
        :not_dispatched,
        Deadline.new(max(remaining(deadline_ms), 1))
      )

    :ok
  end

  defp owner_call(pid, message, deadline_ms) do
    timeout = remaining(deadline_ms)
    GenServer.call(pid, message, timeout)
  catch
    :exit, {:timeout, _detail} -> {:error, :timeout}
    :exit, {:noproc, _detail} -> {:error, :closed}
    :exit, {:normal, _detail} -> {:error, :closed}
    :exit, _reason -> {:error, :closed}
  end

  defp remaining(deadline_ms),
    do: max(deadline_ms - System.monotonic_time(:millisecond), 1)

  defp response_transition_deadline,
    do: System.monotonic_time(:millisecond) + @response_transition_timeout_ms

  defp release_callback(store, admission) do
    fn deadline_ms ->
      Store.release_mcp(store, admission, Deadline.from_expires_at(deadline_ms))
    end
  end

  defp start_response_persistence(state, from, deadline_ms, local_fence, persist) do
    operation_ref = make_ref()
    :ok = LocalFences.block(state.config.local_fence_identity, operation_ref, local_fence)
    state = launch_response_persistence(state, operation_ref, from, deadline_ms, persist, false)
    {:noreply, state}
  end

  defp launch_response_persistence(
         state,
         operation_ref,
         from,
         deadline_ms,
         persist,
         retry?
       ) do
    manager = self()

    {_worker, monitor_ref} =
      spawn_monitor(fn ->
        result = persist.(deadline_ms)
        send(manager, {:response_persistence_finished, operation_ref, result})
      end)

    persistence = %{
      from: from,
      monitor_ref: monitor_ref,
      persist: persist,
      retry?: retry?,
      status: :running
    }

    put_in(state, [:response_persistences, operation_ref], persistence)
  end

  defp finish_response_persistence(state, operation_ref, persistence, result) do
    if is_reference(persistence.monitor_ref),
      do: Process.demonitor(persistence.monitor_ref, [:flush])

    if not is_nil(persistence.from), do: GenServer.reply(persistence.from, result)

    state =
      case result do
        :ok ->
          :ok = LocalFences.resolve(state.config.local_fence_identity, operation_ref)
          update_in(state.response_persistences, &Map.delete(&1, operation_ref))

        {:error, _reason} ->
          failed = %{persistence | from: nil, monitor_ref: nil, status: :failed}
          put_in(state, [:response_persistences, operation_ref], failed)
      end

    state =
      if match?({:error, _reason}, result) and is_list(state.closing) and
           not persistence.retry? do
        retry_response_persistence(state, operation_ref)
      else
        state
      end

    close_or_continue(state)
  end

  defp retry_response_persistence(state, operation_ref) do
    %{persist: persist} = Map.fetch!(state.response_persistences, operation_ref)

    launch_response_persistence(
      state,
      operation_ref,
      nil,
      response_transition_deadline(),
      persist,
      true
    )
  end

  defp retry_failed_persistences(state) do
    Enum.reduce(state.response_persistences, state, fn
      {operation_ref, %{status: :failed}}, current ->
        retry_response_persistence(current, operation_ref)

      {_operation_ref, %{status: :running}}, current ->
        current
    end)
  end

  defp maybe_adopt_unsettled(%{response_persistences: persistences} = state)
       when map_size(persistences) > 0 do
    manager = %__MODULE__{pid: self(), resource: state.config.authority.resource}
    _ = ManagerCleanup.adopt(manager, state.resource_registrar)
    :ok
  end

  defp maybe_adopt_unsettled(_state), do: :ok

  defp close_or_continue(%{closing: waiters, response_persistences: persistences} = state)
       when is_list(waiters) and map_size(persistences) == 0 do
    Enum.each(waiters, &GenServer.reply(&1, :ok))
    {:stop, :normal, state}
  end

  defp close_or_continue(%{closing: waiters, response_persistences: persistences} = state)
       when is_list(waiters) do
    if Enum.all?(persistences, fn {_operation_ref, persistence} ->
         persistence.status == :failed
       end) do
      Enum.each(waiters, &GenServer.reply(&1, {:error, :persistence_failed}))
      {:noreply, %{state | closing: nil}}
    else
      {:noreply, state}
    end
  end

  defp close_or_continue(state), do: {:noreply, state}

  defp persist_rejection(config, generation, deadline_ms) do
    Store.mark_access_rejected(
      config.context.store,
      config.key,
      generation,
      Deadline.from_expires_at(deadline_ms)
    )
  rescue
    _exception -> {:error, :store_error}
  catch
    _kind, _reason -> {:error, :store_error}
  end

  defp persist_scope_requirement(config, generation, scopes, deadline_ms) do
    case Store.upsert_requirement(
           config.context.store,
           config.key,
           generation,
           scopes,
           config.authority.authorization_timeout_ms,
           Deadline.from_expires_at(deadline_ms)
         ) do
      {:ok, _version} -> :ok
      {:error, _reason} = error -> error
    end
  rescue
    _exception -> {:error, :store_error}
  catch
    _kind, _reason -> {:error, :store_error}
  end

  defp close_reason(:timeout), do: :mcp_timeout
  defp close_reason(:closed), do: :mcp_transport_error
  defp close_reason(:stale_before_dispatch), do: :mcp_authorization_required
  defp close_reason(:rejected_before_dispatch), do: :mcp_authorization_required
  defp close_reason(_reason), do: :mcp_authorization_required

  defp local_requirement_satisfied?(
         %{source_generation: source_generation, scopes: required},
         generation,
         %MapSet{} = granted
       ),
       do: generation > source_generation and MapSet.subset?(required, granted)

  defp local_requirement_satisfied?(nil, _generation, _granted), do: true
  defp local_requirement_satisfied?(_requirement, _generation, _granted), do: false

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end
end
