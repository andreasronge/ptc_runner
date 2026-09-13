defmodule PtcRunner.Kernel.ProviderSession.Borrowed do
  @moduledoc """
  Non-owning provider session handle carrying an admission-owned absolute deadline.

  Closing this value is a no-op. Binding registers a fresh run task tracker on
  the shared session without replacing its owner or acquisition deadline.
  """
  @enforce_keys [:session, :deadline, :attestation]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          session: PtcRunner.Kernel.ProviderSession.t(),
          deadline: integer(),
          attestation: binary()
        }
end
