defmodule PtcRunner.Kernel.MCPOAuth.Discovery do
  @moduledoc """
  Bounded final-profile discovery for one installed MCP OAuth authority.

  Discovery performs one unauthenticated `server/discover`, parses at most one
  Bearer challenge, resolves Protected Resource Metadata, then tries RFC 8414
  and OpenID metadata candidates in MCP priority order. A challenge-directed
  resource metadata URL is authoritative and never falls through.
  """

  alias PtcRunner.Kernel.MCPHTTPAdapter
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.BearerChallenge
  alias PtcRunner.Kernel.MCPOAuth.Metadata
  alias PtcRunner.Kernel.MCPOAuth.NetworkPolicy
  alias PtcRunner.Kernel.MCPOAuth.Scope
  alias PtcRunner.Kernel.MCPProtocol
  alias PtcRunner.Kernel.StrictJSON

  @protocol "2026-07-28"
  @max_metadata_bytes 262_144

  @type binding :: %{
          required(:protected_resource) => map(),
          required(:authorization_server) => map(),
          required(:client) => map(),
          required(:requested_scopes) => MapSet.t(binary()),
          required(:required_scopes) => MapSet.t(binary()),
          required(:refresh_authorized) => boolean(),
          required(:revalidation_required) => boolean(),
          required(:freshness_ttl_ms) => non_neg_integer(),
          required(:freshness_anchor_ttl_ms) => non_neg_integer(),
          required(:freshness_deadline_ms) => integer()
        }

  @spec discover(Authority.t(), keyword()) ::
          {:ok, binding()} | {:error, atom()}
  def discover(%Authority{} = authority, opts) when is_list(opts) do
    started_ms = System.monotonic_time(:millisecond)

    with {:ok, deadline_ms} <- deadline(opts, authority),
         {:ok, request} <- request_function(opts, authority),
         {:ok, challenge} <- initial_challenge(authority, request, deadline_ms),
         {:ok, protected, protected_policy} <-
           protected_resource(authority, challenge, request, deadline_ms),
         {:ok, server, server_policy} <-
           authorization_server(authority, request, deadline_ms),
         :ok <- compatible_client_authentication(authority, server),
         {:ok, client, client_policy} <-
           client(authority, server, opts, request, deadline_ms),
         {:ok, required_scopes} <-
           Metadata.select_scopes(challenge, protected, authority),
         {:ok, requested_scopes, refresh_authorized} <-
           refresh_scope(required_scopes, authority, server, client) do
      policies = [protected_policy, server_policy, client_policy]
      freshness_ttl = policies |> Enum.map(& &1.ttl_ms) |> Enum.min()
      elapsed_ms = System.monotonic_time(:millisecond) - started_ms

      {:ok,
       %{
         protected_resource: protected,
         authorization_server: server,
         client: client,
         requested_scopes: requested_scopes,
         required_scopes: required_scopes,
         refresh_authorized: refresh_authorized,
         revalidation_required: freshness_ttl == 0 and Enum.any?(policies, & &1.single_use),
         freshness_ttl_ms: max(freshness_ttl - elapsed_ms, 0),
         freshness_anchor_ttl_ms: freshness_ttl,
         freshness_deadline_ms: started_ms + freshness_ttl
       }}
    end
  end

  def discover(_authority, _opts), do: {:error, :invalid_discovery}

  defp initial_challenge(authority, request, deadline_ms) do
    payload =
      MCPProtocol.request(
        1,
        "server/discover",
        %{},
        %{"client" => %{"name" => "ptc_runner", "version" => "0.x"}}
      )

    headers = [
      {"accept", "application/json, text/event-stream"},
      {"content-type", "application/json"},
      {"mcp-protocol-version", @protocol}
    ]

    with {:ok, body} <- Jason.encode(payload),
         {:ok, %{status: 401} = response} <-
           request.(:post, authority.resource, headers, body, remaining(deadline_ms)),
         {:ok, params} <-
           response
           |> MCPHTTPAdapter.get_header("www-authenticate")
           |> BearerChallenge.parse(),
         {:ok, challenge} <- project_challenge(params, authority) do
      {:ok, challenge}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :mcp_authorization_discovery_failed}
    end
  end

  defp project_challenge(nil, _authority), do: {:ok, %{}}

  defp project_challenge(params, authority) when is_map(params) do
    with {:ok, scopes} <- optional_challenge_scope(Map.get(params, "scope")),
         {:ok, resource_metadata} <-
           optional_metadata_url(Map.get(params, "resource_metadata"), authority) do
      challenge = %{}
      challenge = if scopes, do: Map.put(challenge, :scopes, scopes), else: challenge

      challenge =
        if resource_metadata,
          do: Map.put(challenge, :resource_metadata, resource_metadata),
          else: challenge

      {:ok, challenge}
    end
  end

  defp optional_challenge_scope(nil), do: {:ok, nil}
  defp optional_challenge_scope(value), do: Scope.parse_string(value)

  defp optional_metadata_url(nil, _authority), do: {:ok, nil}

  defp optional_metadata_url(value, authority) when is_binary(value) do
    allow_insecure_loopback =
      match?(
        %URI{scheme: "http", host: host} when host in ["127.0.0.1", "::1"],
        URI.parse(authority.resource)
      )

    case URI.parse(value) do
      %URI{
        scheme: scheme,
        host: host,
        userinfo: nil,
        fragment: nil
      }
      when is_binary(host) and host != "" and
             (scheme == "https" or
                (allow_insecure_loopback and scheme == "http" and
                   host in ["127.0.0.1", "::1"])) ->
        {:ok, value}

      _invalid ->
        {:error, :invalid_resource_metadata_url}
    end
  end

  defp optional_metadata_url(_value, _authority),
    do: {:error, :invalid_resource_metadata_url}

  defp protected_resource(authority, %{resource_metadata: source}, request, deadline_ms) do
    case fetch_json(source, :metadata, request, deadline_ms) do
      {:ok, document, response} ->
        with {:ok, metadata} <-
               Metadata.validate_protected_resource(document, authority, source) do
          {:ok, metadata, freshness_policy(response)}
        end

      _failure ->
        {:error, :mcp_authorization_discovery_failed}
    end
  end

  defp protected_resource(authority, _challenge, request, deadline_ms) do
    authority.resource
    |> Metadata.protected_resource_candidates()
    |> first_valid(fn source ->
      with {:ok, document, response} <-
             fetch_json(source, :metadata, request, deadline_ms),
           {:ok, metadata} <-
             Metadata.validate_protected_resource(document, authority, source) do
        {:ok, metadata, freshness_policy(response)}
      end
    end)
  end

  defp authorization_server(authority, request, deadline_ms) do
    authority.issuer
    |> Metadata.authorization_server_candidates()
    |> first_valid(fn source ->
      with {:ok, document, response} <-
             fetch_json(source, :metadata, request, deadline_ms),
           {:ok, metadata} <-
             Metadata.validate_authorization_server(document, authority, source) do
        {:ok, metadata, freshness_policy(response)}
      end
    end)
  end

  defp client(authority, server, opts, request, deadline_ms) do
    case authority.client.registration do
      :pre_registered ->
        {:ok,
         %{
           source: :pre_registered,
           client_id: authority.client.client_id,
           token_endpoint_auth_method: authority.client.token_endpoint_auth_method,
           grant_types: authority.client.grant_types,
           explicit_refresh_support:
             MapSet.member?(authority.client.grant_types, "refresh_token"),
           redirect: authority.client.redirect
         }, server_freshness_sentinel()}

      :client_id_metadata_document ->
        with true <- server.client_id_metadata_document_supported,
             redirect_uri when is_binary(redirect_uri) <- Keyword.get(opts, :redirect_uri),
             source = authority.client.client_id,
             {:ok, document, response} <-
               fetch_json(source, :client_document, request, deadline_ms),
             {:ok, client} <-
               Metadata.validate_client_document(document, authority, source, redirect_uri) do
          {:ok, client, freshness_policy(response)}
        else
          _invalid -> {:error, :mcp_authorization_discovery_failed}
        end
    end
  end

  defp compatible_client_authentication(authority, server) do
    method = Atom.to_string(authority.client.token_endpoint_auth_method)

    if MapSet.member?(server.token_endpoint_auth_methods_supported, method),
      do: :ok,
      else: {:error, :mcp_authorization_discovery_failed}
  end

  defp refresh_scope(scopes, authority, server, client) do
    refresh_authorized =
      authority.refresh_access == :when_supported and server.explicit_refresh_support and
        client.explicit_refresh_support

    add_offline? =
      refresh_authorized and is_struct(server.scopes_supported, MapSet) and
        MapSet.member?(server.scopes_supported, "offline_access") and
        MapSet.member?(authority.scope_ceiling, "offline_access")

    scopes = if add_offline?, do: MapSet.put(scopes, "offline_access"), else: scopes

    if MapSet.subset?(scopes, authority.scope_ceiling),
      do: {:ok, scopes, refresh_authorized},
      else: {:error, :mcp_authorization_discovery_failed}
  end

  defp fetch_json(source, media_profile, request, deadline_ms) do
    with remaining when remaining > 0 <- remaining(deadline_ms),
         {:ok, %{status: 200} = response} <-
           request.(:get, source, [{"accept", "application/json"}], "", remaining),
         :ok <- content_type(response, media_profile),
         body when is_binary(body) and byte_size(body) in 1..@max_metadata_bytes <-
           response.body,
         {:ok, document} <- StrictJSON.decode(body),
         true <- is_map(document) do
      {:ok, document, response}
    else
      _invalid -> {:error, :invalid_metadata_response}
    end
  end

  defp content_type(response, profile) do
    case MCPHTTPAdapter.get_header(response, "content-type") do
      [value] ->
        with {:ok, type, parameters} <- parse_media_type(value),
             true <- allowed_media_type?(type, profile),
             true <- valid_charset_parameters?(parameters) do
          :ok
        else
          _invalid -> {:error, :invalid_media_type}
        end

      _invalid ->
        {:error, :invalid_media_type}
    end
  end

  defp parse_media_type(value) when is_binary(value) do
    case value |> :binary.split(";", [:global]) |> Enum.map(&String.trim/1) do
      [type | parameters] when type != "" ->
        {:ok, ascii_downcase(type), Enum.map(parameters, &ascii_downcase/1)}

      _invalid ->
        {:error, :invalid_media_type}
    end
  end

  defp allowed_media_type?("application/json", _profile), do: true

  defp allowed_media_type?(type, :client_document),
    do:
      String.starts_with?(type, "application/") and String.ends_with?(type, "+json") and
        byte_size(type) > byte_size("application/+json")

  defp allowed_media_type?(_type, _profile), do: false

  defp valid_charset_parameters?([]), do: true

  defp valid_charset_parameters?([parameter]),
    do: parameter in ["charset=utf-8", "charset=\"utf-8\""]

  defp valid_charset_parameters?(_parameters), do: false

  defp freshness_policy(response) do
    values = MCPHTTPAdapter.get_header(response, "cache-control")

    case {
      Enum.any?(values, &(cache_directive?(&1, "no-store") or cache_directive?(&1, "no-cache"))),
      max_age(values)
    } do
      {true, _max_age} ->
        %{ttl_ms: 0, single_use: true}

      {false, {:ok, max_age}} ->
        remaining_seconds =
          max(min(max_age, 3_600) - response_age(response), 0)

        %{ttl_ms: remaining_seconds * 1_000, single_use: max_age == 0}

      {false, :invalid} ->
        %{ttl_ms: 0, single_use: true}

      {false, :absent} ->
        %{ttl_ms: 60_000, single_use: false}
    end
  end

  defp server_freshness_sentinel, do: %{ttl_ms: 3_600_000, single_use: false}

  defp max_age(values) do
    occurrences =
      values
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.flat_map(fn directive ->
        case String.split(directive, "=", parts: 2) do
          [name, value] ->
            if ascii_downcase(String.trim(name)) == "max-age",
              do: [String.trim(value)],
              else: []

          [name] ->
            if ascii_downcase(String.trim(name)) == "max-age", do: [:malformed], else: []
        end
      end)

    case occurrences do
      [] ->
        :absent

      [seconds] when is_binary(seconds) ->
        case Integer.parse(seconds) do
          {value, ""} when value >= 0 -> {:ok, value}
          _invalid -> :invalid
        end

      _duplicate_or_malformed ->
        :invalid
    end
  end

  defp response_age(response) do
    response
    |> MCPHTTPAdapter.get_header("age")
    |> Enum.reduce(0, fn value, oldest ->
      case value |> String.trim() |> Integer.parse() do
        {age, ""} when age >= 0 -> max(age, oldest)
        _invalid -> oldest
      end
    end)
  end

  defp cache_directive?(value, expected) do
    value
    |> String.split(",")
    |> Enum.any?(&(ascii_downcase(String.trim(&1)) == expected))
  end

  defp first_valid(candidates, callback) do
    Enum.reduce_while(candidates, {:error, :mcp_authorization_discovery_failed}, fn candidate,
                                                                                    _error ->
      case callback.(candidate) do
        {:ok, _metadata, _ttl} = success -> {:halt, success}
        _failure -> {:cont, {:error, :mcp_authorization_discovery_failed}}
      end
    end)
  end

  defp deadline(opts, authority) do
    case Keyword.get(opts, :deadline_ms) do
      value when is_integer(value) -> {:ok, value}
      nil -> {:ok, System.monotonic_time(:millisecond) + authority.authorization_timeout_ms}
      _invalid -> {:error, :invalid_deadline}
    end
  end

  defp request_function(opts, authority) do
    case Keyword.get(opts, :request) do
      function when is_function(function, 5) ->
        {:ok, function}

      nil ->
        resolver = Keyword.get(opts, :resolver)

        {:ok,
         fn method, url, headers, body, timeout_ms ->
           network_request(authority, resolver, method, url, headers, body, timeout_ms)
         end}

      _invalid ->
        {:error, :invalid_request_adapter}
    end
  end

  defp network_request(authority, resolver, method, url, headers, body, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    resolver_opts =
      [deadline_ms: deadline_ms]
      |> then(fn opts -> if is_nil(resolver), do: opts, else: [{:resolver, resolver} | opts] end)

    with {:ok, target} <- NetworkPolicy.resolve(url, authority, resolver_opts),
         remaining_ms when remaining_ms > 0 <-
           deadline_ms - System.monotonic_time(:millisecond) do
      MCPHTTPAdapter.request(
        method: method,
        url: url,
        headers: headers,
        body: body,
        timeout_ms: remaining_ms,
        max_body_bytes: @max_metadata_bytes,
        address: hd(target.addresses),
        connected_peer: NetworkPolicy.peer_verifier(target.addresses)
      )
      |> case do
        {:ok, response} -> {:ok, response}
        {:error, reason, _provenance} -> {:error, reason}
      end
    else
      remaining_ms when is_integer(remaining_ms) and remaining_ms <= 0 ->
        {:error, :timeout}

      error ->
        error
    end
  end

  defp remaining(deadline_ms),
    do: deadline_ms - System.monotonic_time(:millisecond)

  defp ascii_downcase(value) do
    for <<byte <- value>>, into: <<>> do
      if byte in ?A..?Z, do: <<byte + 32>>, else: <<byte>>
    end
  end
end
