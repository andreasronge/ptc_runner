defmodule PtcRunner.Kernel.ResourceRegistrar do
  @moduledoc """
  Scoped acquisition handle for one provider session.

  A registrar belongs to one `PtcRunner.Kernel.ProviderSession` acquisition
  scope and is inert until activated. Successful acquisition commits one
  provider close operation for the scope; failed acquisition aborts it.
  Process and port root admission is added with the shipped-adapter migration,
  so this foundation exposes no unused root-start API. Callers cannot construct
  or retarget registrar handles.
  """

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.ProviderSession

  @enforce_keys [:session, :token, :scope, :attestation]
  defstruct @enforce_keys
  @field_keys Enum.sort([:__struct__ | @enforce_keys])

  @opaque t :: %__MODULE__{
            session: pid(),
            token: reference(),
            scope: reference(),
            attestation: binary()
          }

  @doc false
  @spec new(pid(), reference(), reference()) :: t()
  def new(session, token, scope)
      when is_pid(session) and is_reference(token) and is_reference(scope) do
    registrar = %__MODULE__{
      session: session,
      token: token,
      scope: scope,
      attestation: <<>>
    }

    %{registrar | attestation: Attestation.attest(__MODULE__, payload(registrar))}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = registrar),
    do:
      Enum.sort(Map.keys(registrar)) == @field_keys and is_pid(registrar.session) and
        is_reference(registrar.token) and is_reference(registrar.scope) and
        Attestation.valid?(__MODULE__, payload(registrar), registrar.attestation)

  def valid?(_registrar), do: false

  @doc "Returns the private process that owns this acquisition scope."
  @spec owner(t()) :: pid() | nil
  def owner(%__MODULE__{} = registrar),
    do: if(valid?(registrar), do: registrar.session, else: nil)

  def owner(_registrar), do: nil

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

  defp payload(registrar), do: {registrar.session, registrar.token, registrar.scope}
end
