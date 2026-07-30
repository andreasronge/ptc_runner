defmodule PtcRunner.Kernel.MCPOAuth.Binding do
  @moduledoc false

  @spec identity(map()) :: map()
  def identity(binding) when is_map(binding) do
    %{
      protected_resource:
        Map.take(binding.protected_resource, [
          :source,
          :resource,
          :authorization_servers,
          :scopes_supported
        ]),
      authorization_server:
        Map.take(binding.authorization_server, [
          :source,
          :issuer,
          :authorization_endpoint,
          :token_endpoint,
          :grant_types_supported,
          :explicit_refresh_support,
          :response_modes_supported,
          :token_endpoint_auth_methods_supported,
          :scopes_supported,
          :authorization_response_iss_parameter_supported,
          :client_id_metadata_document_supported
        ]),
      client:
        Map.take(binding.client, [
          :source,
          :client_id,
          :token_endpoint_auth_method,
          :grant_types,
          :explicit_refresh_support,
          :redirect,
          :redirect_uris
        ]),
      requested_scopes: binding.requested_scopes,
      required_scopes: binding.required_scopes,
      refresh_authorized: binding.refresh_authorized
    }
  end
end
