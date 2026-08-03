defmodule PtcRunner.Kernel.ResourceRegistrar do
  @moduledoc """
  Scoped acquisition handle for one provider session.

  A registrar belongs to one `PtcRunner.Kernel.ProviderSession` acquisition
  scope and is inert until activated. Successful acquisition commits one
  provider close operation for the scope; failed acquisition aborts it.
  Each scope has a private signal owner for process roots. A root monitors that
  owner and registers synchronously before its start operation returns. Callers
  cannot construct or retarget registrar handles.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.ProviderSession

  @enforce_keys [
    :session,
    :token,
    :scope,
    :scope_controller,
    :root_owner,
    :cleanup_owner,
    :attestation
  ]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @opaque t :: %__MODULE__{
            session: pid(),
            token: reference(),
            scope: reference(),
            scope_controller: pid(),
            root_owner: pid(),
            cleanup_owner: pid(),
            attestation: binary()
          }

  @doc false
  @spec new(pid(), reference(), reference(), pid(), pid(), pid()) :: t()
  def new(session, token, scope, scope_controller, root_owner, cleanup_owner)
      when is_pid(session) and is_reference(token) and is_reference(scope) and
             is_pid(scope_controller) and is_pid(root_owner) and is_pid(cleanup_owner) do
    registrar = %__MODULE__{
      session: session,
      token: token,
      scope: scope,
      scope_controller: scope_controller,
      root_owner: root_owner,
      cleanup_owner: cleanup_owner,
      attestation: <<>>
    }

    %{registrar | attestation: Attestation.attest(__MODULE__, payload(registrar))}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = registrar),
    do:
      Enum.sort(Map.keys(registrar)) == @field_keys and is_pid(registrar.session) and
        is_reference(registrar.token) and is_reference(registrar.scope) and
        is_pid(registrar.scope_controller) and
        is_pid(registrar.root_owner) and
        is_pid(registrar.cleanup_owner) and
        Attestation.valid?(__MODULE__, payload(registrar), registrar.attestation)

  def valid?(_registrar), do: false

  @doc "Returns the private signal owner for roots in this acquisition scope."
  @spec owner(t()) :: pid() | nil
  def owner(%__MODULE__{} = registrar),
    do: if(valid?(registrar), do: registrar.root_owner, else: nil)

  def owner(_registrar), do: nil

  @doc """
  Registers the calling local process as a root of this active scope.

  A provider process calls this from its init callback after monitoring
  `owner/1` and before its start operation returns.
  """
  @spec register_root(t() | nil) :: :ok | {:error, :resource_registrar_unavailable}
  def register_root(nil), do: :ok

  def register_root(%__MODULE__{} = registrar),
    do: ProviderSession.register_root(registrar)

  def register_root(_registrar), do: {:error, :resource_registrar_unavailable}

  @doc "Removes an adopted terminalization root from scope cleanup."
  @spec handoff_root(t() | nil, pid()) :: :ok | {:error, :resource_registrar_unavailable}
  def handoff_root(nil, _root), do: :ok

  def handoff_root(%__MODULE__{} = registrar, root) when is_pid(root),
    do: ProviderSession.handoff_root(registrar, root)

  def handoff_root(_registrar, _root), do: {:error, :resource_registrar_unavailable}

  @doc false
  @spec activate(t()) :: :ok | {:error, :resource_registrar_unavailable}
  def activate(%__MODULE__{} = registrar), do: ProviderSession.activate_registrar(registrar)
  def activate(_registrar), do: {:error, :resource_registrar_unavailable}

  @doc false
  @spec commit(t(), (-> term()) | nil) ::
          :ok | {:error, :resource_registrar_unavailable}
  def commit(%__MODULE__{} = registrar, close) when is_function(close, 0) or is_nil(close),
    do: ProviderSession.commit_registrar(registrar, close)

  def commit(_registrar, _close), do: {:error, :resource_registrar_unavailable}

  @doc false
  @spec abort(t()) :: :ok | {:error, :provider_cleanup_failed}
  def abort(%__MODULE__{} = registrar), do: ProviderSession.abort_registrar(registrar)
  def abort(_registrar), do: {:error, :provider_cleanup_failed}

  defp payload(registrar),
    do:
      {registrar.session, registrar.token, registrar.scope, registrar.scope_controller,
       registrar.root_owner, registrar.cleanup_owner}
end
