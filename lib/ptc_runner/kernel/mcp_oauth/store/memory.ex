defmodule PtcRunner.Kernel.MCPOAuth.Store.Memory do
  @moduledoc """
  Owner-process, process-local implementation of the MCP OAuth store.

  It is intended for tests, examples, and one foreground CLI invocation. All
  compound behavior operations execute in one serialized GenServer callback, so
  grant CAS, lease transitions, requirement updates, authority claims, and
  retirement fences are atomic. Registered managers are monitored and removed
  from lifecycle tracking when they stop.

  A store is bound to its owner by a monitor rather than a link, so it belongs
  to the process responsible for closing it and not to whichever process
  happened to start it. Owner death destroys the complete store; the death of a
  bounded worker that merely used it does not.
  """

  use GenServer

  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.MCPOAuth.Binding
  alias PtcRunner.Kernel.MCPOAuth.GrantKey
  alias PtcRunner.Kernel.MCPOAuth.Primitives
  alias PtcRunner.Kernel.MCPOAuth.Store

  @behaviour Store

  @close_timeout_ms 1_000

  @enforce_keys [:pid]
  defstruct @enforce_keys

  @type t :: %__MODULE__{pid: pid()}

  @spec start(keyword()) :: {:ok, t()} | {:error, :invalid_owner}
  def start(opts) when is_list(opts) do
    owner = Keyword.fetch!(opts, :owner)

    with true <- is_pid(owner),
         {:ok, pid} <- GenServer.start(__MODULE__, owner) do
      {:ok, %__MODULE__{pid: pid}}
    else
      _invalid -> {:error, :invalid_owner}
    end
  end

  @spec store(t()) :: {:ok, Store.t()} | {:error, :invalid_store}
  def store(%__MODULE__{} = memory),
    do: Store.new(__MODULE__, memory)

  # A detached store outlives the worker that used it, so closing it is a
  # terminal action on the abort path and must not wait indefinitely. A store
  # that answers stops cooperatively and terminates its registered managers; one
  # that will not answer is terminated instead, which is the only stop that
  # cannot run that cleanup.
  @doc false
  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}) do
    reference = Process.monitor(pid)

    _replied =
      try do
        GenServer.call(pid, :close, @close_timeout_ms)
      catch
        :exit, _reason -> :ok
      end

    await_close(pid, reference)
  end

  defp await_close(pid, reference) do
    receive do
      {:DOWN, ^reference, :process, ^pid, _reason} ->
        :ok
    after
      @close_timeout_ms ->
        terminate_store(pid, reference)
    end
  end

  # `HostInstallationOwner.stop/4` sets the precedent: never force-stop a
  # process without first confirming it is the one the handle names. A wedged
  # store cannot answer a call, so identity comes from its start MFA rather than
  # from a reply it will never send. A handle naming anything else closes
  # nothing instead of killing an unrelated process.
  defp terminate_store(pid, reference) do
    if :proc_lib.translate_initial_call(pid) == {__MODULE__, :init, 1} do
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
      end
    else
      Process.demonitor(reference, [:flush])
      :ok
    end
  end

  @impl Store
  def transact(%__MODULE__{pid: pid}, operation, deadline) do
    if Deadline.live?(deadline) do
      GenServer.call(
        pid,
        {:transaction, operation, deadline},
        max(Deadline.remaining(deadline), 1)
      )
    else
      {:error, :timeout}
    end
  catch
    :exit, {:timeout, _detail} ->
      recover_ambiguous_timeout(pid, operation)
      {:error, :timeout}

    :exit, {:noproc, _detail} ->
      {:error, :closed}

    :exit, {:normal, _detail} ->
      {:error, :closed}

    :exit, _reason ->
      {:error, :store_error}
  end

  @impl Store
  def local_identity(%__MODULE__{pid: pid}), do: {__MODULE__, pid}

  @impl Store
  def register_manager(%__MODULE__{pid: pid}, manager) when is_pid(manager) do
    GenServer.call(pid, {:register_manager, manager})
  catch
    :exit, _reason -> {:error, :closed}
  end

  @impl GenServer
  def init(owner) do
    {:ok,
     %{
       owner_ref: Process.monitor(owner),
       managers: %{},
       serial: 0,
       principals: %{},
       authorities: %{},
       grants: %{},
       leases: %{},
       flows: %{},
       requirements: %{},
       admissions: %{},
       retirements: %{}
     }}
  end

  @impl GenServer
  def handle_call({:transaction, operation, deadline}, from, state) do
    if Deadline.live?(deadline),
      do: handle_call(operation, from, state),
      else: {:reply, {:error, :timeout}, state}
  end

  def handle_call({:register_manager, manager}, _from, state) when is_pid(manager) do
    case Map.fetch(state.managers, manager) do
      {:ok, ref} ->
        if Process.alive?(manager) do
          {:reply, :ok, state}
        else
          Process.demonitor(ref, [:flush])
          {:reply, {:error, :closed}, update_in(state.managers, &Map.delete(&1, manager))}
        end

      :error ->
        if Process.alive?(manager) do
          ref = Process.monitor(manager)
          {:reply, :ok, put_in(state.managers[manager], ref)}
        else
          {:reply, {:error, :closed}, state}
        end
    end
  end

  def handle_call(:close, _from, state), do: {:stop, :normal, :ok, state}

  @impl GenServer
  def handle_call({:claim_principal, tenant_id, principal_id}, _from, state) do
    identity = {tenant_id, principal_id}

    case Map.get(state.principals, identity) do
      nil ->
        {epoch, state} = next_id(state, :principal_epoch)
        entry = %{status: :active, epoch: epoch}
        {:reply, {:ok, epoch}, put_in(state.principals[identity], entry)}

      %{status: :active, epoch: epoch} ->
        {:reply, {:ok, epoch}, state}

      %{status: :retired} ->
        {epoch, state} = next_id(state, :principal_epoch)
        entry = %{status: :active, epoch: epoch}
        {:reply, {:ok, epoch}, put_in(state.principals[identity], entry)}

      %{status: :retiring} ->
        {:reply, {:error, :principal_retiring}, state}
    end
  end

  def handle_call({:claim_authorities, tenant_id, authorities}, _from, state) do
    case validate_authority_batch(state, tenant_id, authorities) do
      {:ok, compatible, new} ->
        {state, claimed} =
          Enum.reduce(new, {state, compatible}, fn {installation_id, fingerprint},
                                                   {state, claimed} ->
            {epoch, state} = next_id(state, :authority_epoch)

            entry = %{
              status: :active,
              fingerprint: fingerprint,
              epoch: epoch
            }

            state = put_in(state.authorities[{tenant_id, installation_id}], entry)
            {state, Map.put(claimed, installation_id, epoch)}
          end)

        {:reply, {:ok, claimed}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:time_anchor}, _from, state) do
    {anchor_id, state} = next_id(state, :time_anchor)
    {:reply, {:ok, {:memory_anchor, now_ms(), anchor_id}}, state}
  end

  def handle_call({:load_grant, %GrantKey{} = key}, _from, state) do
    case validate_key(state, key) do
      :ok ->
        grant =
          case Map.get(state.grants, key) do
            nil -> nil
            grant -> loaded_grant(grant)
          end

        {:reply, {:ok, grant}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:acquire_mutation, %GrantKey{} = key, mode, ttl_ms},
        {worker_pid, _tag},
        state
      ) do
    with :ok <- validate_key(state, key),
         {:ok, state} <- clear_expired_undispatched_lease(state, key),
         nil <- Map.get(state.leases, key) do
      {fence, state} = next_id(state, :mutation_fence)
      generation = current_generation(state, key)
      flow_id = if mode == :authorization, do: flow_id(state, key), else: nil
      worker_ref = Process.monitor(worker_pid)

      lease = %{
        fence: fence,
        mode: mode,
        flow_id: flow_id,
        starting_generation: generation,
        phase: :not_dispatched,
        deadline_ms: now_ms() + ttl_ms,
        worker_pid: worker_pid,
        worker_ref: worker_ref
      }

      state = put_in(state.leases[key], lease)
      {:reply, {:ok, %{fence: fence, starting_generation: generation}}, state}
    else
      %{phase: :dispatched} -> {:reply, {:error, :mutation_indeterminate}, state}
      %{} -> {:reply, {:error, :mutation_busy}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:begin_mutation_dispatch, %GrantKey{} = key, fence, binding},
        _from,
        state
      ) do
    with :ok <- validate_key(state, key),
         %{fence: ^fence, phase: :not_dispatched} = lease <- Map.get(state.leases, key),
         true <- lease.deadline_ms > now_ms(),
         true <- lease.starting_generation == current_generation(state, key),
         true <- fresh_anchored_binding?(binding, lease.fence) do
      state = put_in(state.leases[key].phase, :dispatched)
      {:reply, :ok, state}
    else
      false -> {:reply, {:error, :stale_mutation}, state}
      nil -> {:reply, {:error, :stale_mutation}, state}
      %{fence: ^fence, phase: :dispatched} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _invalid -> {:reply, {:error, :stale_mutation}, state}
    end
  end

  def handle_call(
        {:commit_grant, %GrantKey{} = key, fence, grant, ttl_ms, anchor},
        _from,
        state
      ) do
    with :ok <- validate_key(state, key),
         %{fence: ^fence, phase: :dispatched} = lease <- Map.get(state.leases, key),
         true <- lease.deadline_ms > now_ms(),
         true <- lease.starting_generation == current_generation(state, key),
         {:ok, expires_at} <- expiry(anchor, ttl_ms),
         true <- expires_at > now_ms(),
         true <- valid_grant_input?(grant) do
      generation = lease.starting_generation + 1

      stored =
        grant
        |> Map.put(:generation, generation)
        |> Map.put(:expires_at_ms, expires_at)
        |> Map.put(:access_rejected_generation, nil)
        |> Map.put(:status, :active)

      state =
        state
        |> put_in([:grants, key], stored)
        |> delete_lease(key, lease)
        |> finish_authorization_commit(key, lease, stored)

      {:reply, {:ok, loaded_grant(stored)}, state}
    else
      false -> {:reply, {:error, :stale_mutation}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _invalid -> {:reply, {:error, :stale_mutation}, state}
    end
  end

  def handle_call(
        {:fail_mutation, %GrantKey{} = key, fence, outcome},
        _from,
        state
      ) do
    case Map.get(state.leases, key) do
      %{fence: ^fence, phase: phase} = lease ->
        fail_mutation(state, key, lease, phase, outcome)

      _missing ->
        {:reply, {:error, :stale_mutation}, state}
    end
  end

  def handle_call(
        {:recover_mutation, %GrantKey{} = key, fence, :worker_fenced},
        _from,
        state
      ) do
    case Map.get(state.leases, key) do
      %{fence: ^fence} = lease ->
        {:reply, :ok, recover_fenced_mutation(state, key, lease)}

      _missing_or_stale ->
        {:reply, {:error, :stale_mutation}, state}
    end
  end

  def handle_call({:mark_access_rejected, %GrantKey{} = key, generation}, _from, state) do
    case Map.get(state.grants, key) do
      %{generation: ^generation} ->
        state = put_in(state.grants[key].access_rejected_generation, generation)
        {:reply, :ok, state}

      _stale_or_absent ->
        {:reply, :ok, state}
    end
  end

  def handle_call(
        {:admit_mcp, admission, %GrantKey{} = key, generation, worker_pid, ttl_ms},
        _from,
        state
      )
      when is_pid(worker_pid) do
    case validate_key(state, key) do
      :ok ->
        admit_current_grant(state, admission, key, generation, ttl_ms, worker_pid)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release_mcp, admission}, _from, state) do
    {:reply, :ok, delete_admission(state, admission)}
  end

  def handle_call({:begin_flow, %GrantKey{} = key, flow, ttl_ms}, _from, state) do
    with :ok <- validate_key(state, key),
         nil <- live_flow(state, key),
         true <- valid_flow_input?(flow) do
      normalized = normalize_flow_freshness(flow)

      if normalized.binding_freshness_deadline_ms > now_ms() or
           single_use_binding?(flow.binding) do
        {flow_id, state} = next_id(state, :flow)

        stored =
          normalized
          |> Map.put(:id, flow_id)
          |> Map.put(:key, key)
          |> Map.put(:phase, :pending_callback)
          |> Map.put(:starting_generation, current_generation(state, key))
          |> Map.put(:deadline_ms, now_ms() + ttl_ms)

        state = put_in(state.flows[key], stored)
        {:reply, {:ok, public_flow(stored)}, state}
      else
        {:reply, {:error, :stale_flow}, state}
      end
    else
      %{} -> {:reply, {:error, :authorization_in_progress}, state}
      false -> {:reply, {:error, :invalid_flow}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:consume_callback, %GrantKey{} = key, flow_id, callback_state, callback_issuer},
        _from,
        state
      ) do
    with :ok <- validate_key(state, key),
         %{id: ^flow_id, phase: :pending_callback} = flow <- Map.get(state.flows, key),
         true <- flow.deadline_ms > now_ms(),
         true <- Primitives.state_equal?(flow.state, callback_state),
         true <- valid_callback_issuer?(flow, callback_issuer) do
      returned =
        flow
        |> public_flow()
        |> Map.put(:verifier, flow.verifier)

      state =
        state
        |> put_in([:flows, key, :phase], :callback_consumed)
        |> put_in([:flows, key, :state], nil)
        |> put_in([:flows, key, :verifier], nil)

      {:reply, {:ok, returned}, state}
    else
      false -> {:reply, {:error, :invalid_callback}, state}
      nil -> {:reply, {:error, :stale_flow}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _invalid -> {:reply, {:error, :stale_flow}, state}
    end
  end

  def handle_call(
        {:deny_flow, %GrantKey{} = key, flow_id, callback_state, callback_issuer},
        _from,
        state
      ) do
    with :ok <- validate_key(state, key),
         %{id: ^flow_id, phase: :pending_callback} = flow <- Map.get(state.flows, key),
         true <- flow.deadline_ms > now_ms(),
         true <- Primitives.state_equal?(flow.state, callback_state),
         true <- valid_callback_issuer?(flow, callback_issuer) do
      {:reply, :ok, delete_flow_and_lease(state, key, flow_id)}
    else
      false -> {:reply, {:error, :invalid_callback}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _invalid -> {:reply, {:error, :stale_flow}, state}
    end
  end

  def handle_call({:cancel_flow, %GrantKey{} = key, flow_id}, _from, state) do
    case Map.get(state.flows, key) do
      nil ->
        {:reply, :ok, state}

      %{id: ^flow_id, phase: phase} when phase in [:pending_callback, :callback_consumed] ->
        {:reply, :ok, delete_flow_and_lease(state, key, flow_id)}

      %{id: ^flow_id, phase: :code_dispatched} ->
        {:reply, {:error, :code_dispatch_indeterminate}, state}

      _other ->
        {:reply, {:error, :stale_flow}, state}
    end
  end

  def handle_call(
        {:begin_code_dispatch, %GrantKey{} = key, flow_id, fence, binding},
        _from,
        state
      ) do
    with :ok <- validate_key(state, key),
         %{id: ^flow_id, phase: :callback_consumed} = flow <- Map.get(state.flows, key),
         true <- flow.deadline_ms > now_ms(),
         %{fence: ^fence, mode: :authorization, phase: :not_dispatched} = lease <-
           Map.get(state.leases, key),
         true <- lease.deadline_ms > now_ms(),
         true <- lease.starting_generation == flow.starting_generation,
         true <- lease.starting_generation == current_generation(state, key),
         true <- valid_renewed_binding?(flow, binding, lease.fence) do
      renewed_flow = renew_flow_binding(flow, binding)

      state =
        state
        |> put_in([:flows, key], renewed_flow)
        |> put_in([:flows, key, :phase], :code_dispatched)
        |> put_in([:leases, key, :phase], :dispatched)

      {:reply, :ok, state}
    else
      false -> {:reply, {:error, :stale_flow}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _invalid -> {:reply, {:error, :stale_flow}, state}
    end
  end

  def handle_call({:terminalize_flow, %GrantKey{} = key, flow_id}, _from, state) do
    case Map.get(state.flows, key) do
      %{id: ^flow_id} ->
        {:reply, :ok, update_in(state.flows, &Map.delete(&1, key))}

      _absent ->
        {:reply, :ok, state}
    end
  end

  def handle_call(
        {:upsert_requirement, %GrantKey{} = key, generation, scopes, ttl_ms},
        _from,
        state
      ) do
    with :ok <- validate_key(state, key),
         true <- is_struct(scopes, MapSet),
         {:ok, state, version} <-
           upsert_requirement(state, key, generation, scopes, ttl_ms) do
      {:reply, {:ok, version}, state}
    else
      false -> {:reply, {:error, :invalid_requirement}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:load_requirement, %GrantKey{} = key}, _from, state) do
    case validate_key(state, key) do
      :ok ->
        now = now_ms()

        requirement =
          case Map.get(state.requirements, key) do
            %{deadline_ms: deadline} = requirement when deadline > now ->
              Map.drop(requirement, [:deadline_ms])

            _expired_or_absent ->
              nil
          end

        {:reply, {:ok, requirement}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:begin_authority_retirement, tenant_id, installation_id, expected_fingerprint, action,
         idempotency_key, lease_ttl_ms},
        _from,
        state
      ) do
    begin_authority_retirement(
      state,
      tenant_id,
      installation_id,
      expected_fingerprint,
      action,
      idempotency_key,
      lease_ttl_ms
    )
  end

  def handle_call(
        {:complete_authority_retirement, intent_id, coordinator},
        _from,
        state
      ) do
    complete_retirement(state, intent_id, coordinator, :authority)
  end

  def handle_call(
        {:begin_principal_retirement, tenant_id, principal_id, expected_epoch, idempotency_key,
         lease_ttl_ms},
        _from,
        state
      ) do
    begin_principal_retirement(
      state,
      tenant_id,
      principal_id,
      expected_epoch,
      idempotency_key,
      lease_ttl_ms
    )
  end

  def handle_call(
        {:complete_principal_retirement, intent_id, coordinator},
        _from,
        state
      ) do
    complete_retirement(state, intent_id, coordinator, :principal)
  end

  def handle_call({:inspect_retirements, tenant_id}, _from, state) do
    intents =
      state.retirements
      |> Map.values()
      |> Enum.filter(&(&1.tenant_id == tenant_id))
      |> Enum.map(&Map.take(&1, [:id, :kind, :status, :installation_id, :action]))
      |> Enum.sort_by(&inspect(&1.id))

    {:reply, {:ok, intents}, state}
  end

  def handle_call(_operation, _from, state),
    do: {:reply, {:error, :unsupported_store_operation}, state}

  @impl GenServer
  def handle_cast({:recover_admission_timeout, admission}, state) do
    {:noreply, delete_admission(state, admission)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.managers, pid) do
      ^ref ->
        {:noreply, update_in(state.managers, &Map.delete(&1, pid))}

      _other ->
        case worker_record(state, ref) do
          {:lease, key, lease} ->
            {:noreply, recover_fenced_mutation(state, key, lease)}

          {:admission, admission} ->
            {:noreply, delete_admission(state, admission, false)}

          nil ->
            {:noreply, state}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Retry ownership must never outlive the backing store, so manager cleanup
  # belongs to every cooperative stop rather than to the explicit close alone.
  # Owner death stops the store too, and a manager left running against a
  # destroyed store could only fail. The one stop this cannot cover is a store
  # terminated because it stopped answering at all.
  @impl GenServer
  def terminate(_reason, %{managers: managers}) do
    Enum.each(Map.keys(managers), fn manager ->
      if Process.alive?(manager), do: Process.exit(manager, :kill)
    end)

    :ok
  end

  def terminate(_reason, _state), do: :ok

  if {:format_status, 1} in GenServer.behaviour_info(:callbacks) do
    @impl GenServer
    def format_status(status), do: redact_status(status)
  else
    def format_status(status), do: redact_status(status)
  end

  @impl GenServer
  def format_status(_reason, _status), do: [data: [{~c"State", :redacted}]]

  defp validate_authority_batch(state, tenant_id, authorities)
       when is_binary(tenant_id) and is_list(authorities) and length(authorities) <= 128 do
    ids = Enum.map(authorities, fn {id, _fingerprint} -> id end)

    if ids == Enum.uniq(ids) and
         Enum.all?(authorities, fn {id, fingerprint} ->
           is_binary(id) and is_binary(fingerprint)
         end) do
      Enum.reduce_while(authorities, {:ok, %{}, []}, fn {installation_id, fingerprint},
                                                        {:ok, compatible, new} ->
        case Map.get(state.authorities, {tenant_id, installation_id}) do
          %{status: :active, fingerprint: ^fingerprint, epoch: epoch} ->
            {:cont, {:ok, Map.put(compatible, installation_id, epoch), new}}

          %{status: :active} ->
            {:halt, {:error, :authority_collision}}

          %{status: :retiring} ->
            {:halt, {:error, :authority_retiring}}

          nil ->
            {:cont, {:ok, compatible, [{installation_id, fingerprint} | new]}}

          %{status: :retired} ->
            {:cont, {:ok, compatible, [{installation_id, fingerprint} | new]}}
        end
      end)
    else
      {:error, :invalid_authority_batch}
    end
  end

  defp validate_authority_batch(_state, _tenant_id, _authorities),
    do: {:error, :invalid_authority_batch}

  defp validate_key(state, %GrantKey{} = key) do
    principal = Map.get(state.principals, {key.tenant_id, key.principal_id})
    authority = Map.get(state.authorities, {key.tenant_id, key.installation_id})

    cond do
      not match?(%{status: :active, epoch: epoch} when epoch == key.principal_epoch, principal) ->
        {:error, :stale_principal}

      not match?(
        %{status: :active, epoch: epoch, fingerprint: fingerprint}
        when epoch == key.authority_epoch and fingerprint == key.authority_fingerprint,
        authority
      ) ->
        {:error, :stale_authority}

      true ->
        :ok
    end
  end

  defp current_generation(state, key) do
    case Map.get(state.grants, key) do
      %{generation: generation} -> generation
      nil -> 0
    end
  end

  defp admit_current_grant(state, admission, key, generation, ttl_ms, worker_pid) do
    case Map.get(state.grants, key) do
      %{generation: ^generation, status: :active, access_rejected_generation: ^generation} ->
        {:reply, {:error, :rejected_before_dispatch}, state}

      %{generation: ^generation, status: :active} ->
        case admit_requirement(state, key) do
          {:ok, state} ->
            record = %{
              key: key,
              generation: generation,
              deadline_ms: now_ms() + ttl_ms,
              worker_pid: worker_pid,
              worker_ref: Process.monitor(worker_pid)
            }

            state = put_in(state.admissions[admission], record)
            {:reply, {:ok, admission}, state}

          {:error, :authorization_required} ->
            {:reply, {:error, :authorization_required}, state}
        end

      %{status: :active} ->
        {:reply, {:error, :stale_before_dispatch}, state}

      _absent_or_unusable ->
        {:reply, {:error, :authorization_required}, state}
    end
  end

  defp admit_requirement(state, key) do
    now = now_ms()

    case Map.get(state.requirements, key) do
      %{deadline_ms: deadline_ms} when deadline_ms <= now ->
        {:ok, update_in(state.requirements, &Map.delete(&1, key))}

      %{scopes: %MapSet{} = required, source_generation: source_generation} ->
        case Map.get(state.grants, key) do
          %{generation: generation, granted_scopes: %MapSet{} = granted} ->
            if generation > source_generation and MapSet.subset?(required, granted) do
              {:ok, update_in(state.requirements, &Map.delete(&1, key))}
            else
              {:error, :authorization_required}
            end

          _unknown_grant ->
            {:error, :authorization_required}
        end

      nil ->
        {:ok, state}

      _invalid ->
        {:error, :authorization_required}
    end
  end

  defp flow_id(state, key) do
    case live_flow(state, key) do
      %{id: id} -> id
      nil -> nil
    end
  end

  defp clear_expired_undispatched_lease(state, key) do
    now = now_ms()

    case Map.get(state.leases, key) do
      %{phase: :not_dispatched, deadline_ms: deadline} when deadline <= now ->
        {:ok, delete_lease(state, key)}

      %{phase: :dispatched, deadline_ms: deadline} when deadline <= now ->
        {:error, :mutation_indeterminate}

      _active_or_absent ->
        {:ok, state}
    end
  end

  defp fail_mutation(state, key, lease, :not_dispatched, :not_dispatched) do
    state = delete_lease(state, key, lease)
    {:reply, :ok, state}
  end

  defp fail_mutation(state, key, lease, :dispatched, :not_dispatched) do
    state =
      state
      |> delete_lease(key, lease)
      |> maybe_delete_authorization_flow(key, lease)

    {:reply, :ok, state}
  end

  defp fail_mutation(state, key, lease, :dispatched, outcome)
       when outcome in [:possibly_dispatched, :invalid_grant] do
    state =
      cond do
        retiring_key?(state, key) ->
          delete_lease(state, key, lease)

        lease.mode == :authorization ->
          state
          |> delete_lease(key, lease)
          |> update_in([:flows], &Map.delete(&1, key))

        true ->
          poison_grant(state, key, outcome)
      end

    {:reply, :ok, state}
  end

  defp fail_mutation(state, _key, _lease, _phase, _outcome),
    do: {:reply, {:error, :invalid_mutation_outcome}, state}

  defp poison_grant(state, key, outcome) do
    state = delete_lease(state, key)

    case Map.get(state.grants, key) do
      nil ->
        state

      grant ->
        status =
          if outcome == :invalid_grant,
            do: :authorization_required,
            else: :refresh_indeterminate

        poisoned =
          grant
          |> Map.drop([:access_token, :refresh_token])
          |> Map.put(:status, status)
          |> Map.update!(:generation, &(&1 + 1))
          |> Map.put(:access_rejected_generation, nil)

        put_in(state.grants[key], poisoned)
    end
  end

  defp loaded_grant(grant) do
    remaining = max(grant.expires_at_ms - now_ms(), 0)

    grant
    |> Map.delete(:expires_at_ms)
    |> Map.put(:remaining_ttl_ms, remaining)
  end

  defp expiry({:memory_anchor, anchor_ms, {:time_anchor, serial}}, ttl_ms)
       when is_integer(anchor_ms) and is_integer(serial) and is_integer(ttl_ms) and ttl_ms >= 0,
       do: {:ok, anchor_ms + ttl_ms}

  defp expiry(_anchor, _ttl_ms), do: {:error, :invalid_time_anchor}

  defp valid_grant_input?(grant) when is_map(grant) do
    is_binary(Map.get(grant, :access_token)) and
      is_struct(Map.get(grant, :requested_scopes), MapSet) and
      is_struct(Map.get(grant, :granted_scopes), MapSet) and
      is_boolean(Map.get(grant, :refresh_authorized, false))
  end

  defp valid_grant_input?(_grant), do: false

  defp valid_flow_input?(flow) when is_map(flow) do
    is_binary(Map.get(flow, :state)) and is_binary(Map.get(flow, :verifier)) and
      is_binary(Map.get(flow, :issuer)) and
      is_boolean(Map.get(flow, :issuer_required?)) and
      is_struct(Map.get(flow, :requested_scopes), MapSet) and
      is_struct(Map.get(flow, :required_scopes), MapSet)
  end

  defp valid_flow_input?(_flow), do: false

  defp live_flow(state, key) do
    now = now_ms()

    case Map.get(state.flows, key) do
      %{deadline_ms: deadline} = flow when deadline > now -> flow
      _expired_or_absent -> nil
    end
  end

  defp public_flow(flow) do
    flow
    |> Map.drop([
      :state,
      :verifier,
      :key,
      :deadline_ms,
      :binding_freshness_deadline_ms
    ])
    |> Map.put(:remaining_ttl_ms, max(flow.deadline_ms - now_ms(), 0))
    |> Map.put(
      :binding_freshness_remaining_ms,
      max(Map.get(flow, :binding_freshness_deadline_ms, now_ms()) - now_ms(), 0)
    )
    |> Map.put(
      :binding_freshness_fence,
      {:memory_binding_freshness, Map.get(flow, :binding_freshness_deadline_ms, now_ms())}
    )
  end

  defp normalize_flow_freshness(
         %{
           binding: %{
             freshness_anchor: anchor,
             freshness_anchor_ttl_ms: ttl_ms
           }
         } = flow
       )
       when is_integer(ttl_ms) and ttl_ms >= 0 do
    deadline_ms =
      case expiry(anchor, ttl_ms) do
        {:ok, deadline_ms} -> deadline_ms
        {:error, :invalid_time_anchor} -> now_ms()
      end

    flow
    |> put_in(
      [:binding],
      Map.drop(flow.binding, [
        :freshness_anchor,
        :freshness_anchor_ttl_ms,
        :freshness_ttl_ms,
        :freshness_deadline_ms
      ])
    )
    |> Map.put(:binding_freshness_deadline_ms, deadline_ms)
  end

  defp normalize_flow_freshness(flow),
    do: Map.put(flow, :binding_freshness_deadline_ms, now_ms())

  defp finish_authorization_commit(state, key, %{mode: :authorization, flow_id: flow_id}, grant)
       when not is_nil(flow_id) do
    flow = Map.get(state.flows, key)
    state = update_in(state.flows, &Map.delete(&1, key))

    case {flow, Map.get(state.requirements, key)} do
      {%{id: ^flow_id, requirement_version: flow_version},
       %{version: requirement_version, scopes: scopes}}
      when requirement_version <= flow_version ->
        if MapSet.subset?(scopes, grant.granted_scopes),
          do: update_in(state.requirements, &Map.delete(&1, key)),
          else: state

      _other ->
        state
    end
  end

  defp finish_authorization_commit(state, _key, _lease, _grant), do: state

  defp valid_callback_issuer?(%{issuer_required?: true, issuer: issuer}, callback_issuer),
    do: callback_issuer == issuer

  defp valid_callback_issuer?(%{issuer_required?: false, issuer: issuer}, callback_issuer),
    do: is_nil(callback_issuer) or callback_issuer == issuer

  defp valid_renewed_binding?(
         %{binding: old_binding, binding_freshness_deadline_ms: deadline_ms},
         %{freshness_fence: {:memory_binding_freshness, deadline_ms}} = binding,
         _lease_fence
       )
       when is_integer(deadline_ms) do
    Binding.identity(old_binding) == Binding.identity(binding) and deadline_ms > now_ms()
  end

  defp valid_renewed_binding?(
         %{binding: old_binding},
         %{
           freshness_anchor: anchor,
           freshness_anchor_ttl_ms: ttl_ms
         } = binding,
         lease_fence
       )
       when is_integer(ttl_ms) and ttl_ms >= 0 do
    case expiry(anchor, ttl_ms) do
      {:ok, deadline_ms} ->
        (deadline_ms > now_ms() or
           single_use_binding_after_lease?(binding, lease_fence)) and
          Binding.identity(old_binding) == Binding.identity(binding)

      {:error, :invalid_time_anchor} ->
        false
    end
  end

  defp valid_renewed_binding?(_old_binding, _binding, _lease_fence), do: false

  defp renew_flow_binding(flow, %{freshness_fence: _fence} = binding) do
    %{flow | binding: Map.delete(binding, :freshness_fence)}
  end

  defp renew_flow_binding(flow, binding) do
    deadline_ms =
      case expiry(binding.freshness_anchor, binding.freshness_anchor_ttl_ms) do
        {:ok, deadline_ms} -> deadline_ms
        {:error, :invalid_time_anchor} -> now_ms()
      end

    flow
    |> Map.put(
      :binding,
      Map.drop(binding, [
        :freshness_anchor,
        :freshness_anchor_ttl_ms,
        :freshness_ttl_ms,
        :freshness_deadline_ms
      ])
    )
    |> Map.put(:binding_freshness_deadline_ms, deadline_ms)
  end

  defp fresh_anchored_binding?(
         %{
           freshness_anchor: anchor,
           freshness_anchor_ttl_ms: ttl_ms
         } = binding,
         lease_fence
       )
       when is_integer(ttl_ms) and ttl_ms >= 0 do
    case expiry(anchor, ttl_ms) do
      {:ok, deadline_ms} ->
        deadline_ms > now_ms() or single_use_binding_after_lease?(binding, lease_fence)

      {:error, :invalid_time_anchor} ->
        false
    end
  end

  defp fresh_anchored_binding?(_binding, _lease_fence), do: false

  defp single_use_binding?(%{
         revalidation_required: true,
         freshness_anchor: anchor,
         freshness_anchor_ttl_ms: 0
       })
       when is_tuple(anchor),
       do: match?({:ok, _deadline_ms}, expiry(anchor, 0))

  defp single_use_binding?(_binding), do: false

  defp single_use_binding_after_lease?(
         %{
           revalidation_required: true,
           freshness_anchor: {:memory_anchor, _anchor_ms, {:time_anchor, anchor_serial}},
           freshness_anchor_ttl_ms: 0
         },
         {:mutation_fence, lease_serial}
       ),
       do: anchor_serial > lease_serial

  defp single_use_binding_after_lease?(_binding, _lease_fence), do: false

  defp delete_flow_and_lease(state, key, flow_id) do
    state = update_in(state.flows, &Map.delete(&1, key))

    case Map.get(state.leases, key) do
      %{mode: :authorization, phase: :not_dispatched, flow_id: ^flow_id} = lease ->
        delete_lease(state, key, lease)

      _other ->
        state
    end
  end

  defp recover_fenced_mutation(state, key, %{phase: :not_dispatched} = lease) do
    state
    |> delete_lease(key, lease, false)
    |> maybe_delete_authorization_flow(key, lease)
  end

  defp recover_fenced_mutation(state, key, %{phase: :dispatched, mode: :authorization} = lease) do
    state
    |> delete_lease(key, lease, false)
    |> maybe_delete_authorization_flow(key, lease)
  end

  defp recover_fenced_mutation(state, key, %{phase: :dispatched, mode: :refresh} = lease) do
    if retiring_key?(state, key) do
      delete_lease(state, key, lease, false)
    else
      poison_grant(state, key, :possibly_dispatched)
    end
  end

  defp maybe_delete_authorization_flow(state, key, %{mode: :authorization, flow_id: flow_id}) do
    case Map.get(state.flows, key) do
      %{id: ^flow_id} -> update_in(state.flows, &Map.delete(&1, key))
      _other -> state
    end
  end

  defp maybe_delete_authorization_flow(state, _key, _lease), do: state

  defp delete_lease(state, key, lease \\ nil, demonitor? \\ true) do
    lease = lease || Map.get(state.leases, key)

    if demonitor? and is_map(lease) and is_reference(Map.get(lease, :worker_ref)),
      do: Process.demonitor(lease.worker_ref, [:flush])

    update_in(state.leases, &Map.delete(&1, key))
  end

  defp delete_admission(state, admission, demonitor? \\ true) do
    record = Map.get(state.admissions, admission)

    if demonitor? and is_map(record) and is_reference(Map.get(record, :worker_ref)),
      do: Process.demonitor(record.worker_ref, [:flush])

    update_in(state.admissions, &Map.delete(&1, admission))
  end

  defp recover_ambiguous_timeout(
         pid,
         {:admit_mcp, admission, %GrantKey{}, _generation, _worker_pid, _ttl}
       ) do
    GenServer.cast(pid, {:recover_admission_timeout, admission})
  end

  defp recover_ambiguous_timeout(_pid, _operation), do: :ok

  defp worker_record(state, ref) do
    Enum.find_value(state.leases, fn {key, lease} ->
      if Map.get(lease, :worker_ref) == ref, do: {:lease, key, lease}
    end) ||
      Enum.find_value(state.admissions, fn {admission, record} ->
        if Map.get(record, :worker_ref) == ref, do: {:admission, admission}
      end)
  end

  defp upsert_requirement(state, key, generation, scopes, ttl_ms) do
    grant = Map.get(state.grants, key)
    now = now_ms()

    with true <- is_integer(generation) and generation >= 0,
         true <- is_integer(ttl_ms) and ttl_ms > 0,
         %{generation: current} = current_grant when generation <= current <- grant do
      previous =
        case Map.get(state.requirements, key) do
          %{deadline_ms: deadline_ms} = requirement when deadline_ms > now ->
            requirement

          _expired_or_absent ->
            nil
        end

      required = MapSet.union(scopes, Map.get(previous || %{}, :scopes, MapSet.new()))
      source_generation = max(generation, Map.get(previous || %{}, :source_generation, 0))

      if current_grant.status == :active and current > source_generation and
           is_struct(Map.get(current_grant, :granted_scopes), MapSet) and
           MapSet.subset?(required, current_grant.granted_scopes) do
        state = update_in(state.requirements, &Map.delete(&1, key))
        {:ok, state, requirement_version(state, key)}
      else
        {version, state} = next_requirement_version(state)

        requirement = %{
          scopes: required,
          source_generation: source_generation,
          version: version,
          deadline_ms: now + ttl_ms
        }

        {:ok, put_in(state.requirements[key], requirement), version}
      end
    else
      false -> {:error, :invalid_requirement}
      _stale_or_absent -> {:error, :stale_generation}
    end
  end

  defp next_requirement_version(state) do
    version = state.serial + 1
    {version, %{state | serial: version}}
  end

  defp requirement_version(state, key) do
    case Map.get(state.requirements, key) do
      %{version: version} -> version
      nil -> 0
    end
  end

  defp begin_authority_retirement(
         state,
         tenant_id,
         installation_id,
         expected_fingerprint,
         action,
         idempotency_key,
         lease_ttl_ms
       ) do
    identity = {tenant_id, installation_id}

    case Map.get(state.authorities, identity) do
      %{
        status: :active,
        fingerprint: ^expected_fingerprint,
        epoch: epoch
      } ->
        {intent_id, state} = next_id(state, :retirement_intent)
        {coordinator, state} = next_id(state, :coordinator)

        intent = %{
          id: intent_id,
          kind: :authority,
          status: :draining,
          tenant_id: tenant_id,
          installation_id: installation_id,
          expected_epoch: epoch,
          expected_fingerprint: expected_fingerprint,
          action: action,
          idempotency_key: idempotency_key,
          coordinator: coordinator,
          coordinator_deadline_ms: now_ms() + lease_ttl_ms
        }

        state =
          state
          |> put_in([:authorities, identity, :status], :retiring)
          |> put_in([:authorities, identity, :intent_id], intent_id)
          |> put_in([:retirements, intent_id], intent)
          |> cancel_pre_dispatch_for(&authority_key?(&1, tenant_id, installation_id))

        {:reply, {:ok, %{intent_id: intent_id, coordinator: coordinator}}, state}

      %{status: :retiring, intent_id: intent_id} ->
        intent = Map.fetch!(state.retirements, intent_id)

        if intent.idempotency_key == idempotency_key and intent.action == action do
          renew_retirement_coordinator(state, intent, lease_ttl_ms)
        else
          {:reply, {:error, :conflicting_retirement}, state}
        end

      %{status: :active} ->
        {:reply, {:error, :stale_authority}, state}

      _absent_or_retired ->
        {:reply, {:error, :stale_authority}, state}
    end
  end

  defp begin_principal_retirement(
         state,
         tenant_id,
         principal_id,
         expected_epoch,
         idempotency_key,
         lease_ttl_ms
       ) do
    identity = {tenant_id, principal_id}

    case Map.get(state.principals, identity) do
      %{status: :active, epoch: ^expected_epoch} ->
        {intent_id, state} = next_id(state, :retirement_intent)
        {coordinator, state} = next_id(state, :coordinator)

        intent = %{
          id: intent_id,
          kind: :principal,
          status: :draining,
          tenant_id: tenant_id,
          principal_id: principal_id,
          expected_epoch: expected_epoch,
          idempotency_key: idempotency_key,
          coordinator: coordinator,
          coordinator_deadline_ms: now_ms() + lease_ttl_ms
        }

        state =
          state
          |> put_in([:principals, identity, :status], :retiring)
          |> put_in([:principals, identity, :intent_id], intent_id)
          |> put_in([:retirements, intent_id], intent)
          |> cancel_pre_dispatch_for(&principal_key?(&1, tenant_id, principal_id))

        {:reply, {:ok, %{intent_id: intent_id, coordinator: coordinator}}, state}

      %{status: :retiring, intent_id: intent_id} ->
        intent = Map.fetch!(state.retirements, intent_id)

        if intent.idempotency_key == idempotency_key do
          renew_retirement_coordinator(state, intent, lease_ttl_ms)
        else
          {:reply, {:error, :conflicting_retirement}, state}
        end

      _stale ->
        {:reply, {:error, :stale_principal}, state}
    end
  end

  defp complete_retirement(state, intent_id, coordinator, kind) do
    with %{kind: ^kind, coordinator: ^coordinator, status: :draining} = intent <-
           Map.get(state.retirements, intent_id),
         true <- intent.coordinator_deadline_ms > now_ms(),
         false <- retirement_has_admissions?(state, intent),
         false <- retirement_has_dispatched_mutations?(state, intent) do
      {result, state} = finish_retirement(state, intent)
      {:reply, {:ok, result}, state}
    else
      true -> {:reply, {:error, :retirement_not_drained}, state}
      false -> {:reply, {:error, :retirement_not_drained}, state}
      nil -> {:reply, {:error, :stale_retirement}, state}
      _invalid -> {:reply, {:error, :stale_retirement}, state}
    end
  end

  defp renew_retirement_coordinator(state, intent, lease_ttl_ms) do
    if intent.coordinator_deadline_ms > now_ms() do
      {:reply, {:ok, %{intent_id: intent.id, coordinator: intent.coordinator}}, state}
    else
      {coordinator, state} = next_id(state, :coordinator)

      state =
        state
        |> put_in([:retirements, intent.id, :coordinator], coordinator)
        |> put_in(
          [:retirements, intent.id, :coordinator_deadline_ms],
          now_ms() + lease_ttl_ms
        )

      {:reply, {:ok, %{intent_id: intent.id, coordinator: coordinator}}, state}
    end
  end

  defp finish_retirement(state, %{kind: :authority} = intent) do
    matcher = &authority_key?(&1, intent.tenant_id, intent.installation_id)
    state = delete_matching_state(state, matcher)
    identity = {intent.tenant_id, intent.installation_id}

    case intent.action do
      {:replace, fingerprint} ->
        {epoch, state} = next_id(state, :authority_epoch)
        entry = %{status: :active, fingerprint: fingerprint, epoch: epoch}

        state =
          state
          |> put_in([:authorities, identity], entry)
          |> put_in([:retirements, intent.id, :status], :completed)

        {epoch, state}

      :release ->
        {epoch, state} = next_id(state, :authority_epoch)
        entry = %{status: :retired, epoch: epoch}

        state =
          state
          |> put_in([:authorities, identity], entry)
          |> put_in([:retirements, intent.id, :status], :completed)

        {epoch, state}
    end
  end

  defp finish_retirement(state, %{kind: :principal} = intent) do
    matcher = &principal_key?(&1, intent.tenant_id, intent.principal_id)
    state = delete_matching_state(state, matcher)
    identity = {intent.tenant_id, intent.principal_id}
    {epoch, state} = next_id(state, :principal_epoch)

    state =
      state
      |> put_in([:principals, identity], %{status: :retired, epoch: epoch})
      |> put_in([:retirements, intent.id, :status], :completed)

    {epoch, state}
  end

  defp cancel_pre_dispatch_for(state, matcher) do
    state.leases
    |> Enum.filter(fn {key, lease} ->
      matcher.(key) and lease.phase == :not_dispatched
    end)
    |> Enum.each(fn {_key, lease} ->
      Process.demonitor(lease.worker_ref, [:flush])
    end)

    leases =
      Map.reject(state.leases, fn {key, lease} ->
        matcher.(key) and lease.phase == :not_dispatched
      end)

    flows = Map.reject(state.flows, fn {key, _flow} -> matcher.(key) end)
    requirements = Map.reject(state.requirements, fn {key, _record} -> matcher.(key) end)
    %{state | leases: leases, flows: flows, requirements: requirements}
  end

  defp delete_matching_state(state, matcher) do
    state.leases
    |> Enum.filter(fn {key, _lease} -> matcher.(key) end)
    |> Enum.each(fn {_key, lease} ->
      Process.demonitor(lease.worker_ref, [:flush])
    end)

    %{
      state
      | grants: Map.reject(state.grants, fn {key, _record} -> matcher.(key) end),
        leases: Map.reject(state.leases, fn {key, _record} -> matcher.(key) end),
        flows: Map.reject(state.flows, fn {key, _record} -> matcher.(key) end),
        requirements: Map.reject(state.requirements, fn {key, _record} -> matcher.(key) end)
    }
  end

  defp retirement_has_admissions?(state, intent) do
    Enum.any?(state.admissions, fn {_id, admission} ->
      retirement_matches?(intent, admission.key)
    end)
  end

  defp retirement_has_dispatched_mutations?(state, intent) do
    Enum.any?(state.leases, fn {key, lease} ->
      lease.phase == :dispatched and retirement_matches?(intent, key)
    end)
  end

  defp retirement_matches?(%{kind: :authority} = intent, key),
    do: authority_key?(key, intent.tenant_id, intent.installation_id)

  defp retirement_matches?(%{kind: :principal} = intent, key),
    do: principal_key?(key, intent.tenant_id, intent.principal_id)

  defp authority_key?(%GrantKey{} = key, tenant_id, installation_id),
    do: key.tenant_id == tenant_id and key.installation_id == installation_id

  defp principal_key?(%GrantKey{} = key, tenant_id, principal_id),
    do: key.tenant_id == tenant_id and key.principal_id == principal_id

  defp retiring_key?(state, key) do
    match?(
      %{status: :retiring},
      Map.get(state.principals, {key.tenant_id, key.principal_id})
    ) or
      match?(
        %{status: :retiring},
        Map.get(state.authorities, {key.tenant_id, key.installation_id})
      )
  end

  defp next_id(state, kind) do
    serial = state.serial + 1
    {{kind, serial}, %{state | serial: serial}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp redact_status(status) do
    Map.new(status, fn
      {key, _value} when key in [:state, :message, :reason] -> {key, :redacted}
      {:log, _value} -> {:log, []}
      key_value -> key_value
    end)
  end
end
