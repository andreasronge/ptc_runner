defmodule PtcRunner.Kernel.MCPOAuth.GrantKey do
  @moduledoc """
  Opaque, epoch-fenced identity for one principal's OAuth grant.

  Exact principal and client identity must never enter public snapshots,
  events, traces, or inspection. The custom `Inspect` implementation is
  therefore constant and redacted.
  """

  @enforce_keys [
    :tenant_id,
    :principal_id,
    :installation_id,
    :resource,
    :issuer,
    :client_id,
    :principal_epoch,
    :authority_fingerprint,
    :authority_epoch
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          tenant_id: binary(),
          principal_id: binary(),
          installation_id: binary(),
          resource: binary(),
          issuer: binary(),
          client_id: binary(),
          principal_epoch: term(),
          authority_fingerprint: binary(),
          authority_epoch: term()
        }
end
