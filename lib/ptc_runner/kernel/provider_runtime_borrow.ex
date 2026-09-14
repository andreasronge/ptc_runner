defmodule PtcRunner.Kernel.ProviderRuntime.Borrow do
  @moduledoc """
  Caller-monitored token for retained provider capabilities.

  Return it explicitly after the run finishes; caller death also releases it.
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
          attestation: binary()
        }
end
