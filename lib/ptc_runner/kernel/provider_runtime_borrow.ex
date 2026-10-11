defmodule PtcRunner.Kernel.ProviderRuntime.Borrow do
  @moduledoc """
  Caller-monitored token for retained provider capabilities.

  Return it explicitly after the run finishes; caller death seals and settles transport work before release.
  The session carries the absolute admission deadline. This token owns no
  provider and cannot extend runtime readiness or prevent a bounded drain.
  """
  @enforce_keys [
    :runtime,
    :monitor,
    :caller,
    :session,
    :providers,
    :registry,
    :plan_identity,
    :execution,
    :mcp_token,
    :attestation
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          runtime: pid(),
          monitor: reference(),
          caller: pid(),
          session: PtcRunner.Kernel.ProviderSession.Borrowed.t(),
          providers: map(),
          registry: PtcRunner.Kernel.ProviderRegistry.t(),
          plan_identity: tuple(),
          execution: PtcRunner.Kernel.ProviderExecution.t(),
          mcp_token: struct(),
          attestation: binary()
        }

  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.PreparedRun
  alias PtcRunner.Kernel.ProviderSession

  @doc false
  @spec plan_identity(PreparedRun.t()) :: tuple()
  def plan_identity(prepared),
    do:
      {prepared.catalog_attestation, prepared.effective_application_digest,
       prepared.installation_config_digests}

  @doc false
  @spec valid_borrow?(term()) :: boolean()
  def valid_borrow?(%__MODULE__{} = borrow) do
    Attestation.valid?(
      __MODULE__,
      Map.delete(Map.from_struct(borrow), :attestation),
      borrow.attestation
    ) and
      ProviderSession.alive?(borrow.session) and
      call(borrow.runtime, {:valid_borrow, borrow.monitor}, false)
  end

  def valid_borrow?(_borrow), do: false

  @doc false
  def call(pid, request, fallback, timeout \\ 5_000) do
    GenServer.call(pid, request, timeout)
  catch
    :exit, _reason -> fallback
  end

  @spec return(t()) :: :ok | {:error, atom()}
  def return(%__MODULE__{caller: caller} = borrow) when caller == self(),
    do: call(borrow.runtime, {:return, borrow}, {:error, :provider_runtime_lost}, :infinity)

  def return(_borrow), do: {:error, :invalid_provider_runtime}
  @doc false
  @spec release_borrow(t()) :: :ok | {:error, atom()}
  def release_borrow(%__MODULE__{} = borrow),
    do: call(borrow.runtime, {:release, borrow}, {:error, :provider_runtime_lost}, :infinity)

  @doc false
  def settle_borrow(%__MODULE__{} = borrow),
    do: call(borrow.runtime, {:settle, borrow}, {:error, :provider_runtime_lost}, :infinity)

  @doc false
  def hold_borrow(%__MODULE__{} = borrow),
    do: call(borrow.runtime, {:hold, borrow}, {:error, :provider_runtime_lost})
end
