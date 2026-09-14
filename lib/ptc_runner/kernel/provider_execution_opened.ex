defmodule PtcRunner.Kernel.ProviderExecution.Opened do
  @moduledoc "Acquired serving resources owned by the provider runtime, never by individual runs."
  @enforce_keys [:session, :providers, :snapshot_sites, :registry]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          session: PtcRunner.Kernel.ProviderSession.t(),
          providers: map(),
          snapshot_sites: [map()],
          registry: PtcRunner.Kernel.ProviderRegistry.t()
        }
end
