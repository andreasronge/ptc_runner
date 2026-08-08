defmodule PtcRunner.Kernel.ResourceRegistrar do
  @moduledoc """
  Scoped acquisition handle for one provider session.

  A registrar belongs to one `PtcRunner.Kernel.ProviderSession` acquisition
  scope and is inert until activated. Successful acquisition commits one
  provider close operation for the scope; failed acquisition aborts it.
  Each scope has a private signal owner for process roots. A root monitors that
  owner and registers synchronously before its start operation returns.

  A handle cannot be *retargeted*: every field is covered by the sealed
  attestation `valid?/1` checks on entry, so mutating one invalidates it. It can
  be *constructed* — `new/8` attests whatever arguments it is given, and
  `PtcRunner.Kernel.Attestation` is explicitly not a security boundary against
  code running in the same VM. What contains a minted handle is the session's
  own authority rather than this struct: it honours only scope references it
  opened, fences activate and commit with the deadline it sealed for itself
  rather than the one the handle carries, and clamps an abort to a budget it
  installed.
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

  # Opaque, and `PtcRunner.Kernel.ProviderSession` reaches the fields it needs
  # through the `@doc false` accessors below rather than by matching the struct.
  # The fence is worth keeping because roughly ten other modules hold a `t()`
  # without ever reading one of its fields, and the static check is what keeps
  # it that way.
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

  @doc false
  @spec register_root(t() | nil, timeout()) ::
          :ok | {:error, :resource_registrar_unavailable}
  def register_root(nil, _timeout), do: :ok

  def register_root(%__MODULE__{} = registrar, timeout),
    do: ProviderSession.register_root(registrar, timeout)

  def register_root(_registrar, _timeout), do: {:error, :resource_registrar_unavailable}

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
  # `:provider_cleanup_failed` is the settle path's answer when a wedged session
  # is killed and its mailbox then shows it had taken ownership of the closer.
  # Omitting it made every caller's match on that reason unreachable to the type
  # checker, which is how the branch that reports an unreleased resource came to
  # look like dead code.
  @spec commit(t(), (-> term()) | nil) ::
          :ok | {:error, :resource_registrar_unavailable | :provider_cleanup_failed}
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

  # `ProviderSession` addresses a scope by these three, and adopts a
  # terminalization root through the fourth. They complete the accessor set the
  # two budgets above started, so the session never has to match this struct and
  # the opaque fence stays intact for every other holder of a `t()`.
  @doc false
  @spec session(t()) :: pid()
  def session(%__MODULE__{} = registrar), do: registrar.session

  @doc false
  @spec token(t()) :: reference()
  def token(%__MODULE__{} = registrar), do: registrar.token

  @doc false
  @spec scope(t()) :: reference()
  def scope(%__MODULE__{} = registrar), do: registrar.scope

  @doc false
  @spec cleanup_owner(t()) :: pid()
  def cleanup_owner(%__MODULE__{} = registrar), do: registrar.cleanup_owner
end
