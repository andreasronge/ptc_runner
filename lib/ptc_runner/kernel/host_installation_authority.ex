defmodule PtcRunner.Kernel.HostInstallationAuthority do
  @moduledoc false

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.HostCredentialLease
  alias PtcRunner.Kernel.HostInstallationOwner

  @enforce_keys [:pid, :token, :role, :fence, :lease_owner, :lease_fence, :lease_table]
  defstruct @enforce_keys ++ [attestation: nil]
  @field_keys Enum.sort([:__struct__, :attestation | @enforce_keys])

  @type role :: :catalog | :registry
  @type fence :: :atomics.atomics_ref()
  @type t :: %__MODULE__{
          pid: pid(),
          token: reference(),
          role: role(),
          fence: fence(),
          lease_owner: pid(),
          lease_fence: :atomics.atomics_ref(),
          lease_table: reference(),
          attestation: binary() | nil
        }

  @doc false
  @spec new(pid(), reference(), fence(), pid(), :atomics.atomics_ref(), reference()) ::
          {:ok, t()} | {:error, :invalid_host_installation_authority}
  def new(pid, token, fence, lease_owner, lease_fence, lease_table)
      when is_pid(pid) and is_reference(token) and is_reference(fence) and
             is_pid(lease_owner) and is_reference(lease_fence) and is_reference(lease_table) do
    if HostInstallationOwner.authenticated?(pid, token) and
         HostCredentialLease.bound_to?(lease_owner, pid, lease_fence, lease_table) do
      build(pid, token, :catalog, fence, lease_owner, lease_fence, lease_table)
    else
      {:error, :invalid_host_installation_authority}
    end
  end

  def new(_pid, _token, _fence, _lease_owner, _lease_fence, _lease_table),
    do: {:error, :invalid_host_installation_authority}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{attestation: attestation} = authority),
    do:
      Enum.sort(Map.keys(authority)) == @field_keys and is_pid(authority.pid) and
        is_reference(authority.token) and authority.role in [:catalog, :registry] and
        is_reference(authority.fence) and is_pid(authority.lease_owner) and
        is_reference(authority.lease_fence) and is_reference(authority.lease_table) and
        Attestation.valid?(__MODULE__, payload(authority), attestation)

  def valid?(_authority), do: false

  @spec invoke(t(), term()) :: term()
  def invoke(%__MODULE__{} = authority, request) do
    if valid?(authority),
      do:
        HostInstallationOwner.invoke(
          authority.pid,
          authority.token,
          authority.role,
          authority.fence,
          request
        ),
      else: {:error, :invalid_host_installation}
  end

  def invoke(_authority, _request), do: {:error, :invalid_host_installation}

  @doc false
  @spec with_credential_lease(t(), (-> term())) :: term()
  def with_credential_lease(%__MODULE__{} = authority, operation)
      when is_function(operation, 0) do
    case HostCredentialLease.claim(
           authority.lease_owner,
           authority.lease_fence,
           authority.lease_table
         ) do
      {:ok, lease} when is_reference(lease) ->
        try do
          result = operation.()

          case release_credential_lease(authority, lease) do
            :ok -> result
            {:error, :credential_resolution_failed} = error -> error
          end
        catch
          kind, reason ->
            stacktrace = __STACKTRACE__
            _ = release_credential_lease(authority, lease)
            :erlang.raise(kind, reason, stacktrace)
        end

      _error ->
        {:error, :credential_resolution_failed}
    end
  end

  def with_credential_lease(_authority, _operation),
    do: {:error, :credential_resolution_failed}

  defp release_credential_lease(authority, lease),
    do:
      HostCredentialLease.release(
        authority.lease_owner,
        authority.lease_table,
        lease,
        self()
      )

  @spec transfer_to_registry(t() | nil) ::
          {:ok, t() | nil} | {:error, :invalid_host_installation_authority}
  def transfer_to_registry(nil), do: {:ok, nil}

  def transfer_to_registry(%__MODULE__{role: :catalog} = authority) do
    with true <- valid?(authority),
         {:ok, registry_authority} <-
           build(
             authority.pid,
             authority.token,
             :registry,
             authority.fence,
             authority.lease_owner,
             authority.lease_fence,
             authority.lease_table
           ),
         transition <- System.unique_integer([:positive, :monotonic]) + 1,
         :ok <- admit(authority.fence, transition) do
      _result =
        HostInstallationOwner.transfer(
          authority.pid,
          authority.token,
          :catalog,
          :registry,
          self(),
          transition
        )

      case reconcile(authority.fence, transition) do
        :committed -> {:ok, registry_authority}
        :cancelled -> {:error, :invalid_host_installation_authority}
      end
    else
      _invalid -> {:error, :invalid_host_installation_authority}
    end
  end

  def transfer_to_registry(_authority), do: {:error, :invalid_host_installation_authority}

  @spec close(t() | nil) :: :ok
  def close(%__MODULE__{} = authority) do
    if valid?(authority) do
      if authority.role == :catalog, do: cancel_pending(authority.fence)
      release(authority)
    else
      :ok
    end
  end

  def close(_authority), do: :ok

  @doc false
  @spec release(t() | nil) :: :ok
  def release(%__MODULE__{} = authority) do
    HostCredentialLease.close(
      authority.lease_owner,
      authority.lease_fence,
      authority.lease_table
    )

    HostInstallationOwner.stop(
      authority.pid,
      authority.token,
      authority.role,
      authority.fence
    )
  end

  def release(_authority), do: :ok

  defp build(pid, token, role, fence, lease_owner, lease_fence, lease_table) do
    authority = %__MODULE__{
      pid: pid,
      token: token,
      role: role,
      fence: fence,
      lease_owner: lease_owner,
      lease_fence: lease_fence,
      lease_table: lease_table
    }

    {:ok, %{authority | attestation: Attestation.attest(__MODULE__, payload(authority))}}
  end

  defp admit(fence, transition) do
    case :atomics.compare_exchange(fence, 1, 1, transition) do
      :ok -> :ok
      _current -> {:error, :invalid_host_installation_authority}
    end
  catch
    :error, _reason -> {:error, :invalid_host_installation_authority}
  end

  defp reconcile(fence, transition) do
    committed = -transition

    case :atomics.get(fence, 1) do
      ^committed ->
        :committed

      ^transition ->
        case :atomics.compare_exchange(fence, 1, transition, 1) do
          :ok -> :cancelled
          ^committed -> :committed
          _other -> :cancelled
        end

      _other ->
        :cancelled
    end
  catch
    :error, _reason -> :cancelled
  end

  defp cancel_pending(fence) do
    case :atomics.get(fence, 1) do
      pending when pending > 1 ->
        _cancelled_or_committed = :atomics.compare_exchange(fence, 1, pending, 1)
        :ok

      _catalog_or_committed ->
        :ok
    end
  catch
    :error, _reason -> :ok
  end

  defp payload(authority),
    do:
      {authority.pid, authority.token, authority.role, authority.fence, authority.lease_owner,
       authority.lease_fence, authority.lease_table}
end
