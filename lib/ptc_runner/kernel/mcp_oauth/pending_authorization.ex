defmodule PtcRunner.Kernel.MCPOAuth.PendingAuthorization do
  @moduledoc """
  Opaque handle for one explicit authorization interaction.

  `url` is intentionally accessible so a trusted UI can present it exactly
  once. The custom `Inspect` implementation never renders the URL, state,
  principal identity, redirect, or authority.
  """

  @enforce_keys [
    :key,
    :flow_id,
    :url,
    :redirect_uri,
    :deadline_ms,
    :authority,
    :store
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          key: PtcRunner.Kernel.MCPOAuth.GrantKey.t(),
          flow_id: term(),
          url: binary(),
          redirect_uri: binary(),
          deadline_ms: integer(),
          authority: PtcRunner.Kernel.MCPOAuth.Authority.t(),
          store: PtcRunner.Kernel.MCPOAuth.Store.t()
        }
end
