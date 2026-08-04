defmodule PtcRunner.Kernel.MCPOAuth.Store do
  @moduledoc """
  Atomic authorization-store boundary for MCP OAuth state.

  Store adapters implement one closed transaction callback. The public
  functions below define the supported operation vocabulary; callers cannot
  submit arbitrary functions or inspect adapter-owned state. Every operation
  that reads or mutates a grant is fenced by both principal and authority
  epochs carried in `GrantKey`.

  Persistent adapters must encrypt secret fields at rest, use an
  adapter-authoritative clock, and make each operation crash-atomic at this
  callback boundary. PtcRunner ships only the owner-process in-memory adapter;
  no durable adapter or persistence recommendation is included.

  `c:transact/3` receives the absolute deadline captured by this boundary.
  Adapters must check it again at their serialized mutation boundary and return
  `{:error, :timeout}` without changing state when it has expired. Store
  wrappers must forward that exact deadline rather than replacing it with a new
  relative timeout.
  """

  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.MCPOAuth.GrantKey

  @typedoc "Opaque adapter tuple."
  @type t :: {module(), term()}

  @typedoc "Closed transaction command issued by this module."
  @type operation :: tuple()

  @typedoc false
  @type request_deadline :: Deadline.t() | pos_integer()

  @callback transact(adapter_state :: term(), operation(), Deadline.t()) :: term()
  @callback local_identity(adapter_state :: term()) :: term()
  @callback register_manager(adapter_state :: term(), pid()) :: :ok | {:error, atom()}
  @optional_callbacks local_identity: 1, register_manager: 2

  @spec new(module(), term()) :: {:ok, t()} | {:error, :invalid_store}
  def new(module, adapter_state) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :transact, 3),
      do: {:ok, {module, adapter_state}},
      else: {:error, :invalid_store}
  end

  def new(_module, _adapter_state), do: {:error, :invalid_store}

  @doc """
  Returns an opaque process-local identity shared by wrappers of one store.

  Adapters that can be wrapped should implement `c:local_identity/1` and return
  the same non-secret identity for every handle to the same backing store.
  """
  @spec local_identity(t()) :: term()
  def local_identity({module, adapter_state} = store) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :local_identity, 1),
      do: module.local_identity(adapter_state),
      else: store
  end

  @doc false
  @spec register_manager(t(), pid()) :: :ok | {:error, atom()}
  def register_manager({module, adapter_state}, manager)
      when is_atom(module) and is_pid(manager) do
    if Code.ensure_loaded?(module) and function_exported?(module, :register_manager, 2),
      do: module.register_manager(adapter_state, manager),
      else: :ok
  rescue
    _exception -> {:error, :store_error}
  catch
    _kind, _reason -> {:error, :store_error}
  end

  @spec claim_principal(t(), binary(), binary(), request_deadline()) ::
          {:ok, term()} | {:error, atom()}
  def claim_principal(store, tenant_id, principal_id, timeout),
    do: call(store, {:claim_principal, tenant_id, principal_id}, timeout)

  @spec claim_authorities(t(), binary(), [{binary(), binary()}], request_deadline()) ::
          {:ok, %{binary() => term()}} | {:error, atom()}
  def claim_authorities(store, tenant_id, authorities, timeout),
    do: call(store, {:claim_authorities, tenant_id, authorities}, timeout)

  @spec time_anchor(t(), request_deadline()) :: {:ok, term()} | {:error, atom()}
  def time_anchor(store, timeout), do: call(store, {:time_anchor}, timeout)

  @spec load_grant(t(), GrantKey.t(), request_deadline()) ::
          {:ok, map() | nil} | {:error, atom()}
  def load_grant(store, %GrantKey{} = key, timeout),
    do: call(store, {:load_grant, key}, timeout)

  @spec acquire_mutation(
          t(),
          GrantKey.t(),
          :refresh | :authorization,
          pos_integer(),
          request_deadline()
        ) ::
          {:ok, %{fence: term(), starting_generation: non_neg_integer()}}
          | {:error, atom()}
  def acquire_mutation(store, %GrantKey{} = key, mode, ttl_ms, timeout)
      when mode in [:refresh, :authorization] and is_integer(ttl_ms) and ttl_ms > 0,
      do: call(store, {:acquire_mutation, key, mode, ttl_ms}, timeout)

  @spec begin_mutation_dispatch(t(), GrantKey.t(), term(), map(), request_deadline()) ::
          :ok | {:error, atom()}
  def begin_mutation_dispatch(store, %GrantKey{} = key, fence, binding, timeout)
      when is_map(binding),
      do: call(store, {:begin_mutation_dispatch, key, fence, binding}, timeout)

  @spec commit_grant(
          t(),
          GrantKey.t(),
          term(),
          map(),
          pos_integer(),
          term(),
          request_deadline()
        ) :: {:ok, map()} | {:error, atom()}
  def commit_grant(store, %GrantKey{} = key, fence, grant, ttl_ms, anchor, timeout),
    do: call(store, {:commit_grant, key, fence, grant, ttl_ms, anchor}, timeout)

  @spec fail_mutation(
          t(),
          GrantKey.t(),
          term(),
          :not_dispatched | :possibly_dispatched | :invalid_grant,
          request_deadline()
        ) :: :ok | {:error, atom()}
  def fail_mutation(store, %GrantKey{} = key, fence, outcome, timeout),
    do: call(store, {:fail_mutation, key, fence, outcome}, timeout)

  @doc """
  Recovers one exact mutation only after its dispatch worker has been
  irreversibly fenced.

  A refresh is poisoned and an authorization-code flow is terminalized. Lease
  expiry alone is not proof of fencing and is insufficient for this operation.
  """
  @spec recover_mutation(t(), GrantKey.t(), term(), :worker_fenced, request_deadline()) ::
          :ok | {:error, atom()}
  def recover_mutation(store, %GrantKey{} = key, fence, :worker_fenced, timeout),
    do: call(store, {:recover_mutation, key, fence, :worker_fenced}, timeout)

  @spec mark_access_rejected(t(), GrantKey.t(), non_neg_integer(), request_deadline()) ::
          :ok | {:error, atom()}
  def mark_access_rejected(store, %GrantKey{} = key, generation, timeout),
    do: call(store, {:mark_access_rejected, key, generation}, timeout)

  @spec admit_mcp(t(), GrantKey.t(), non_neg_integer(), pos_integer(), request_deadline()) ::
          {:ok, term()} | {:error, atom()}
  def admit_mcp(store, %GrantKey{} = key, generation, ttl_ms, timeout) do
    admit_mcp(store, key, generation, self(), ttl_ms, timeout)
  end

  @spec admit_mcp(
          t(),
          GrantKey.t(),
          non_neg_integer(),
          pid(),
          pos_integer(),
          request_deadline()
        ) ::
          {:ok, term()} | {:error, atom()}
  def admit_mcp(store, %GrantKey{} = key, generation, worker_pid, ttl_ms, timeout)
      when is_pid(worker_pid) do
    admission = {:mcp_admission, make_ref()}
    call(store, {:admit_mcp, admission, key, generation, worker_pid, ttl_ms}, timeout)
  end

  @spec release_mcp(t(), term(), request_deadline()) :: :ok | {:error, atom()}
  def release_mcp(store, admission, timeout),
    do: call(store, {:release_mcp, admission}, timeout)

  @spec begin_flow(t(), GrantKey.t(), map(), pos_integer(), request_deadline()) ::
          {:ok, map()} | {:error, atom()}
  def begin_flow(store, %GrantKey{} = key, flow, ttl_ms, timeout),
    do: call(store, {:begin_flow, key, flow, ttl_ms}, timeout)

  @spec consume_callback(
          t(),
          GrantKey.t(),
          term(),
          binary(),
          binary() | nil,
          request_deadline()
        ) ::
          {:ok, map()} | {:error, atom()}
  def consume_callback(store, %GrantKey{} = key, flow_id, state, issuer, timeout),
    do: call(store, {:consume_callback, key, flow_id, state, issuer}, timeout)

  @spec deny_flow(t(), GrantKey.t(), term(), binary(), binary() | nil, request_deadline()) ::
          :ok | {:error, atom()}
  def deny_flow(store, %GrantKey{} = key, flow_id, state, issuer, timeout),
    do: call(store, {:deny_flow, key, flow_id, state, issuer}, timeout)

  @spec cancel_flow(t(), GrantKey.t(), term(), request_deadline()) ::
          :ok | {:error, atom()}
  def cancel_flow(store, %GrantKey{} = key, flow_id, timeout),
    do: call(store, {:cancel_flow, key, flow_id}, timeout)

  @spec begin_code_dispatch(t(), GrantKey.t(), term(), term(), map(), request_deadline()) ::
          :ok | {:error, atom()}
  def begin_code_dispatch(store, %GrantKey{} = key, flow_id, fence, binding, timeout)
      when is_map(binding),
      do: call(store, {:begin_code_dispatch, key, flow_id, fence, binding}, timeout)

  @spec terminalize_flow(t(), GrantKey.t(), term(), request_deadline()) ::
          :ok | {:error, atom()}
  def terminalize_flow(store, %GrantKey{} = key, flow_id, timeout),
    do: call(store, {:terminalize_flow, key, flow_id}, timeout)

  @spec upsert_requirement(
          t(),
          GrantKey.t(),
          non_neg_integer(),
          MapSet.t(binary()),
          pos_integer(),
          request_deadline()
        ) :: {:ok, non_neg_integer()} | {:error, atom()}
  def upsert_requirement(store, %GrantKey{} = key, generation, scopes, ttl_ms, timeout),
    do: call(store, {:upsert_requirement, key, generation, scopes, ttl_ms}, timeout)

  @spec load_requirement(t(), GrantKey.t(), request_deadline()) ::
          {:ok, map() | nil} | {:error, atom()}
  def load_requirement(store, %GrantKey{} = key, timeout),
    do: call(store, {:load_requirement, key}, timeout)

  @spec begin_authority_retirement(
          t(),
          binary(),
          binary(),
          binary(),
          {:replace, binary()} | :release,
          binary(),
          pos_integer(),
          request_deadline()
        ) :: {:ok, map()} | {:error, atom()}
  def begin_authority_retirement(
        store,
        tenant_id,
        installation_id,
        expected_fingerprint,
        action,
        idempotency_key,
        lease_ttl_ms,
        timeout
      ),
      do:
        call(
          store,
          {:begin_authority_retirement, tenant_id, installation_id, expected_fingerprint, action,
           idempotency_key, lease_ttl_ms},
          timeout
        )

  @spec complete_authority_retirement(t(), term(), term(), request_deadline()) ::
          {:ok, term()} | {:error, atom()}
  def complete_authority_retirement(store, intent_id, coordinator, timeout),
    do: call(store, {:complete_authority_retirement, intent_id, coordinator}, timeout)

  @spec begin_principal_retirement(
          t(),
          binary(),
          binary(),
          term(),
          binary(),
          pos_integer(),
          request_deadline()
        ) :: {:ok, map()} | {:error, atom()}
  def begin_principal_retirement(
        store,
        tenant_id,
        principal_id,
        expected_epoch,
        idempotency_key,
        lease_ttl_ms,
        timeout
      ),
      do:
        call(
          store,
          {:begin_principal_retirement, tenant_id, principal_id, expected_epoch, idempotency_key,
           lease_ttl_ms},
          timeout
        )

  @spec complete_principal_retirement(t(), term(), term(), request_deadline()) ::
          {:ok, term()} | {:error, atom()}
  def complete_principal_retirement(store, intent_id, coordinator, timeout),
    do: call(store, {:complete_principal_retirement, intent_id, coordinator}, timeout)

  @spec inspect_retirements(t(), binary(), request_deadline()) ::
          {:ok, [map()]} | {:error, atom()}
  def inspect_retirements(store, tenant_id, timeout),
    do: call(store, {:inspect_retirements, tenant_id}, timeout)

  defp call(store, operation, timeout) when is_integer(timeout) and timeout > 0,
    do: call(store, operation, Deadline.new(timeout))

  defp call({module, adapter_state}, operation, deadline) when is_atom(module) do
    cond do
      not Deadline.valid?(deadline) -> {:error, :invalid_store}
      Deadline.expired?(deadline) -> {:error, :timeout}
      true -> module.transact(adapter_state, operation, deadline)
    end
  rescue
    _exception -> {:error, :store_error}
  catch
    _kind, _reason -> {:error, :store_error}
  end

  defp call(_store, _operation, _timeout), do: {:error, :invalid_store}
end
