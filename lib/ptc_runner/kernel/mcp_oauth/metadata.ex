defmodule PtcRunner.Kernel.MCPOAuth.Metadata do
  @moduledoc """
  Pure candidate construction and semantic validation for MCP OAuth metadata.

  Decoding must use `StrictJSON` before these functions are called. Validators
  project only fields used by PtcRunner's supported authorization profile and
  reject DPoP, signed Protected Resource Metadata, PAR requirements, and
  unsupported client authentication before browser interaction.
  """

  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.NetworkPolicy
  alias PtcRunner.Kernel.MCPOAuth.Primitives
  alias PtcRunner.Kernel.MCPOAuth.Scope

  @max_endpoints 16
  @max_redirects 16

  @spec protected_resource_candidates(binary()) :: [binary()]
  def protected_resource_candidates(resource) do
    %URI{scheme: scheme, authority: authority, path: path, query: query} = URI.parse(resource)
    origin = scheme <> "://" <> authority
    base = origin <> "/.well-known/oauth-protected-resource"

    path_candidate =
      if path in [nil, "", "/"] do
        base
      else
        base <> path <> if(is_nil(query), do: "", else: "?" <> query)
      end

    Enum.uniq([path_candidate, base])
  end

  @spec authorization_server_candidates(binary()) :: [binary()]
  def authorization_server_candidates(issuer) do
    %URI{scheme: scheme, authority: authority, path: path} = URI.parse(issuer)
    origin = scheme <> "://" <> authority
    suffix = issuer_suffix(path)

    oauth = origin <> "/.well-known/oauth-authorization-server" <> suffix
    oidc_inserted = origin <> "/.well-known/openid-configuration" <> suffix
    oidc_appended = append_well_known(issuer)

    Enum.uniq([oauth, oidc_inserted, oidc_appended])
  end

  @spec validate_protected_resource(map(), Authority.t(), binary()) ::
          {:ok, map()} | {:error, :invalid_protected_resource_metadata}
  def validate_protected_resource(document, %Authority{} = authority, source)
      when is_map(document) and is_binary(source) do
    with false <- Map.has_key?(document, "signed_metadata"),
         dpop when is_boolean(dpop) <-
           Map.get(document, "dpop_bound_access_tokens_required", false),
         false <- dpop,
         resource when is_binary(resource) <- Map.get(document, "resource"),
         {:ok, canonical_resource} <-
           Authority.resource(resource, endpoint_options(authority.resource)),
         true <- canonical_resource == authority.resource,
         servers when is_list(servers) and length(servers) in 1..@max_endpoints <-
           Map.get(document, "authorization_servers"),
         true <- servers == Enum.uniq(servers) and Enum.all?(servers, &is_binary/1),
         true <- authority.issuer in servers,
         {:ok, scopes} <- optional_scopes(Map.get(document, "scopes_supported")) do
      {:ok,
       %{
         source: source,
         resource: canonical_resource,
         authorization_servers: servers,
         scopes_supported: scopes
       }}
    else
      _invalid -> {:error, :invalid_protected_resource_metadata}
    end
  end

  def validate_protected_resource(_document, _authority, _source),
    do: {:error, :invalid_protected_resource_metadata}

  @spec validate_authorization_server(map(), Authority.t(), binary()) ::
          {:ok, map()} | {:error, :invalid_authorization_server_metadata}
  def validate_authorization_server(document, %Authority{} = authority, source)
      when is_map(document) and is_binary(source) do
    with issuer when is_binary(issuer) <- Map.get(document, "issuer"),
         true <- issuer == authority.issuer,
         authorization_endpoint when is_binary(authorization_endpoint) <-
           Map.get(document, "authorization_endpoint"),
         {:ok, authorization_endpoint} <-
           Primitives.authorization_endpoint(
             authorization_endpoint,
             endpoint_options(authority.issuer)
           ),
         true <- NetworkPolicy.endpoint_allowed?(authorization_endpoint, authority),
         token_endpoint when is_binary(token_endpoint) <- Map.get(document, "token_endpoint"),
         {:ok, token_endpoint} <-
           Primitives.token_endpoint(token_endpoint, endpoint_options(authority.issuer)),
         true <- NetworkPolicy.endpoint_allowed?(token_endpoint, authority),
         {:ok, response_types} <-
           string_set(Map.get(document, "response_types_supported"), required: true),
         true <- MapSet.member?(response_types, "code"),
         {:ok, grant_types, explicit_refresh?} <- grant_types(document),
         true <- MapSet.member?(grant_types, "authorization_code"),
         {:ok, response_modes} <- response_modes(document),
         true <- MapSet.member?(response_modes, "query"),
         {:ok, pkce_methods} <-
           string_set(Map.get(document, "code_challenge_methods_supported"),
             required: true
           ),
         true <- MapSet.member?(pkce_methods, "S256"),
         {:ok, authentication_methods} <- authentication_methods(document),
         {:ok, scopes} <- optional_scopes(Map.get(document, "scopes_supported")),
         {:ok, issuer_response?} <-
           optional_boolean(
             Map.get(document, "authorization_response_iss_parameter_supported"),
             false
           ),
         {:ok, cimd_supported?} <-
           optional_boolean(
             Map.get(document, "client_id_metadata_document_supported"),
             false
           ),
         {:ok, par_required?} <-
           optional_boolean(Map.get(document, "require_pushed_authorization_requests"), false),
         false <- par_required? do
      {:ok,
       %{
         source: source,
         issuer: issuer,
         authorization_endpoint: authorization_endpoint,
         token_endpoint: token_endpoint,
         response_types_supported: response_types,
         grant_types_supported: grant_types,
         explicit_refresh_support: explicit_refresh?,
         response_modes_supported: response_modes,
         token_endpoint_auth_methods_supported: authentication_methods,
         scopes_supported: scopes,
         authorization_response_iss_parameter_supported: issuer_response?,
         client_id_metadata_document_supported: cimd_supported?
       }}
    else
      _invalid -> {:error, :invalid_authorization_server_metadata}
    end
  end

  def validate_authorization_server(_document, _authority, _source),
    do: {:error, :invalid_authorization_server_metadata}

  @spec validate_client_document(map(), Authority.t(), binary(), binary()) ::
          {:ok, map()} | {:error, :invalid_client_metadata_document}
  def validate_client_document(document, %Authority{} = authority, source, redirect_uri)
      when is_map(document) and is_binary(source) and is_binary(redirect_uri) do
    client = authority.client

    with :client_id_metadata_document <- client.registration,
         true <- source == client.client_id,
         client_id when is_binary(client_id) <- Map.get(document, "client_id"),
         true <- client_id == client.client_id,
         client_name when is_binary(client_name) <- Map.get(document, "client_name"),
         true <- bounded_string?(client_name, 256),
         redirect_uris when is_list(redirect_uris) and length(redirect_uris) in 1..@max_redirects <-
           Map.get(document, "redirect_uris"),
         true <- redirect_uris == Enum.uniq(redirect_uris),
         true <- Enum.all?(redirect_uris, &bounded_string?(&1, 4_096)),
         true <- redirect_authorized?(client.redirect, redirect_uri, redirect_uris),
         "none" <- Map.get(document, "token_endpoint_auth_method"),
         false <- forbidden_client_key?(document),
         {:ok, grant_types, explicit_grants?} <- client_grant_types(document),
         true <- MapSet.member?(grant_types, "authorization_code"),
         {:ok, response_types} <- client_response_types(document),
         true <- MapSet.member?(response_types, "code"),
         {:ok, par_required?} <-
           optional_boolean(Map.get(document, "require_pushed_authorization_requests"), false),
         false <- par_required?,
         {:ok, dpop_required?} <-
           optional_boolean(Map.get(document, "dpop_bound_access_tokens"), false),
         false <- dpop_required? do
      {:ok,
       %{
         source: source,
         client_id: client_id,
         client_name: client_name,
         redirect_uris: redirect_uris,
         token_endpoint_auth_method: :none,
         grant_types: grant_types,
         explicit_refresh_support:
           explicit_grants? and MapSet.member?(grant_types, "refresh_token"),
         response_types: response_types
       }}
    else
      _invalid -> {:error, :invalid_client_metadata_document}
    end
  end

  def validate_client_document(_document, _authority, _source, _redirect_uri),
    do: {:error, :invalid_client_metadata_document}

  @spec select_scopes(map(), map(), Authority.t()) ::
          {:ok, MapSet.t(binary())} | {:error, :authorization_required}
  def select_scopes(challenge, protected_resource, %Authority{} = authority)
      when is_map(challenge) and is_map(protected_resource) do
    selected =
      cond do
        is_struct(Map.get(challenge, :scopes), MapSet) ->
          challenge.scopes

        is_struct(protected_resource.scopes_supported, MapSet) ->
          protected_resource.scopes_supported

        MapSet.size(authority.default_scopes) > 0 ->
          authority.default_scopes

        true ->
          nil
      end

    if is_struct(selected, MapSet) and MapSet.size(selected) > 0 and
         Scope.subset?(selected, authority.scope_ceiling) do
      {:ok, selected}
    else
      {:error, :authorization_required}
    end
  end

  defp optional_scopes(nil), do: {:ok, nil}
  defp optional_scopes(value), do: Scope.parse_list(value)

  defp grant_types(document) do
    case Map.fetch(document, "grant_types_supported") do
      :error ->
        {:ok, MapSet.new(["authorization_code", "implicit"]), false}

      {:ok, values} ->
        with {:ok, set} <- string_set(values, required: true),
             do: {:ok, set, MapSet.member?(set, "refresh_token")}
    end
  end

  defp response_modes(document) do
    case Map.fetch(document, "response_modes_supported") do
      :error -> {:ok, MapSet.new(["query", "fragment"])}
      {:ok, values} -> string_set(values, required: true)
    end
  end

  defp authentication_methods(document) do
    case Map.fetch(document, "token_endpoint_auth_methods_supported") do
      :error -> {:ok, MapSet.new(["client_secret_basic"])}
      {:ok, values} -> string_set(values, required: true)
    end
  end

  defp client_grant_types(document) do
    case Map.fetch(document, "grant_types") do
      :error ->
        {:ok, MapSet.new(["authorization_code"]), false}

      {:ok, values} ->
        with {:ok, set} <- string_set(values, required: true),
             do: {:ok, set, true}
    end
  end

  defp client_response_types(document) do
    case Map.fetch(document, "response_types") do
      :error -> {:ok, MapSet.new(["code"])}
      {:ok, values} -> string_set(values, required: true)
    end
  end

  defp string_set(value, opts) when is_list(value) and is_list(opts) do
    required? = Keyword.fetch!(opts, :required)

    if length(value) <= 32 and (not required? or value != []) and
         value == Enum.uniq(value) and
         Enum.all?(value, &bounded_string?(&1, 256)) do
      {:ok, MapSet.new(value)}
    else
      {:error, :invalid_metadata}
    end
  end

  defp string_set(_value, _opts), do: {:error, :invalid_metadata}

  defp optional_boolean(nil, default), do: {:ok, default}
  defp optional_boolean(value, _default) when is_boolean(value), do: {:ok, value}
  defp optional_boolean(_value, _default), do: {:error, :invalid_metadata}

  defp forbidden_client_key?(document) do
    Enum.any?(
      ~w(client_secret client_secret_expires_at jwks jwks_uri),
      &Map.has_key?(document, &1)
    )
  end

  defp redirect_authorized?({:https, installed}, redirect_uri, advertised),
    do: redirect_uri in installed and redirect_uri in advertised

  defp redirect_authorized?({:loopback, descriptor}, redirect_uri, advertised) do
    with {:ok, runtime} <- loopback_parts(redirect_uri),
         true <- runtime.host == descriptor.host and runtime.path == descriptor.path do
      Enum.any?(advertised, fn registered ->
        case loopback_parts(registered) do
          {:ok, candidate} ->
            candidate.host == descriptor.host and candidate.path == descriptor.path

          _invalid ->
            false
        end
      end)
    else
      _invalid -> false
    end
  end

  defp loopback_parts(value) do
    case URI.parse(value) do
      %URI{
        scheme: "http",
        host: host,
        port: port,
        path: path,
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when host in ["127.0.0.1", "::1"] and is_integer(port) and is_binary(path) ->
        {:ok, %{host: host, port: port, path: path}}

      _invalid ->
        {:error, :invalid_redirect}
    end
  end

  defp issuer_suffix(path) when path in [nil, "", "/"], do: ""
  defp issuer_suffix(path), do: "/" <> String.trim_leading(path, "/")

  defp append_well_known(issuer) do
    if String.ends_with?(issuer, "/"),
      do: issuer <> ".well-known/openid-configuration",
      else: issuer <> "/.well-known/openid-configuration"
  end

  defp bounded_string?(value, max_bytes),
    do:
      is_binary(value) and byte_size(value) in 1..max_bytes and String.valid?(value) and
        not String.contains?(value, [<<0>>, "\r", "\n"])

  defp endpoint_options(url) do
    case URI.parse(url) do
      %URI{scheme: "http", host: host} when host in ["127.0.0.1", "::1"] ->
        [allow_insecure_loopback: true]

      _secure ->
        []
    end
  end
end
