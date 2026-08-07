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
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.ProviderSession

  @enforce_keys [
    :session,
    :token,
    :scope,
    :scope_controller,
    :root_owner,
    :cleanup_owner,
    :operation_deadline,
    :cleanup_timeout_ms,
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
            operation_deadline: Deadline.t() | nil,
            cleanup_timeout_ms: pos_integer(),
            attestation: binary()
          }

  @doc false
  @spec new(
          pid(),
          reference(),
          reference(),
          pid(),
          pid(),
          pid(),
          Deadline.t() | nil,
          pos_integer()
        ) :: t()
  def new(
        session,
        token,
        scope,
        scope_controller,
        root_owner,
        cleanup_owner,
        operation_deadline,
        cleanup_timeout_ms
      )
      when is_pid(session) and is_reference(token) and is_reference(scope) and
             is_pid(scope_controller) and is_pid(root_owner) and is_pid(cleanup_owner) and
             is_integer(cleanup_timeout_ms) and cleanup_timeout_ms > 0 do
    registrar = %__MODULE__{
      session: session,
      token: token,
      scope: scope,
      scope_controller: scope_controller,
      root_owner: root_owner,
      cleanup_owner: cleanup_owner,
      operation_deadline: operation_deadline,
      cleanup_timeout_ms: cleanup_timeout_ms,
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
        (is_nil(registrar.operation_deadline) or Deadline.valid?(registrar.operation_deadline)) and
        is_integer(registrar.cleanup_timeout_ms) and registrar.cleanup_timeout_ms > 0 and
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

  # The two budgets are sealed with the handle: a registrar that could be
  # rebound to a longer deadline, or to a cleanup budget its session never
  # installed, would let a caller widen the bounds its own scope spends.
  defp payload(registrar),
    do:
      {registrar.session, registrar.token, registrar.scope, registrar.scope_controller,
       registrar.root_owner, registrar.cleanup_owner, registrar.operation_deadline,
       registrar.cleanup_timeout_ms}

  @doc false
  @spec operation_deadline(t()) :: Deadline.t() | nil
  def operation_deadline(%__MODULE__{} = registrar), do: registrar.operation_deadline

  @doc false
  @spec cleanup_timeout_ms(t()) :: pos_integer()
  def cleanup_timeout_ms(%__MODULE__{} = registrar), do: registrar.cleanup_timeout_ms
end
