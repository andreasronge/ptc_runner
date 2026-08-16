defmodule PtcRunner.Kernel.MCPOAuth.Authority do
  @moduledoc """
  Validated host authority for one OAuth-protected Streamable HTTP MCP server.

  The struct is safe to pass only inside trusted host/runtime code. Its
  versioned fingerprint covers every default-expanded security field so any
  authority edit fences old grants. The struct itself is intentionally omitted
  from connector snapshots and public events.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.MCPEndpoint
  alias PtcRunner.Kernel.MCPOAuth.Scope

  @max_id_bytes 256
  @max_client_id_bytes 2_048
  @max_origins 32
  @max_redirects 16
  @max_authorization_timeout_ms 900_000
  @max_unknown_expiry_ttl_ms 86_400_000

  @enforce_keys [
    :installation_id,
    :issuer,
    :resource,
    :scope_ceiling,
    :default_scopes,
    :refresh_access,
    :authorization_timeout_ms,
    :unknown_expiry_ttl_ms,
    :additional_origins,
    :private_network_origins,
    :client,
    :fingerprint
  ]
  defstruct @enforce_keys

  @type token_endpoint_auth_method :: :none | :client_secret_basic
  @type registration :: :pre_registered | :client_id_metadata_document

  @type client :: %{
          required(:registration) => registration(),
          required(:client_id) => binary(),
          required(:token_endpoint_auth_method) => token_endpoint_auth_method(),
          required(:grant_types) => MapSet.t(binary()),
          required(:redirect) =>
            {:loopback, %{host: binary(), path: binary()}}
            | {:https, [binary()]},
          optional(:client_secret_binding) => binary()
        }

  @type t :: %__MODULE__{
          installation_id: binary(),
          issuer: binary(),
          resource: binary(),
          scope_ceiling: Scope.scope_set(),
          default_scopes: Scope.scope_set(),
          refresh_access: :none | :when_supported,
          authorization_timeout_ms: pos_integer(),
          unknown_expiry_ttl_ms: pos_integer(),
          additional_origins: [binary()],
          private_network_origins: [binary()],
          client: client(),
          fingerprint: binary()
        }

  @doc """
  Validates the host JSON OAuth block for one installed endpoint.

  `credential_names` is the complete host credential-name set. Only a
  confidential client's binding identifier is checked; its secret is not
  resolved.
  """
  @spec from_host(map(), binary(), MapSet.t(binary()), keyword()) ::
          {:ok, t()} | {:error, :invalid_oauth_authority}
  def from_host(value, endpoint, credential_names, opts \\ [])

  def from_host(value, endpoint, %MapSet{} = credential_names, opts)
      when is_map(value) and is_binary(endpoint) and is_list(opts) do
    allowed =
      ~w(
        installation_id issuer resource scope_ceiling default_scopes
        refresh_access authorization_timeout_ms unknown_expiry_ttl_ms
        network client
      )

    required = ~w(installation_id issuer scope_ceiling client)

    with :ok <- exact_keys(value, allowed, required),
         installation_id <- value["installation_id"],
         true <- bounded_opaque?(installation_id, @max_id_bytes),
         {:ok, issuer} <- issuer(value["issuer"], opts),
         {:ok, endpoint_resource} <- resource(endpoint, opts),
         {:ok, configured_resource} <-
           optional_resource(Map.get(value, "resource"), endpoint_resource, opts),
         true <- configured_resource == endpoint_resource,
         {:ok, scope_ceiling} <-
           Scope.parse_list(value["scope_ceiling"], allow_empty: true),
         {:ok, default_scopes} <-
           Scope.parse_list(Map.get(value, "default_scopes", []), allow_empty: true),
         true <- Scope.subset?(default_scopes, scope_ceiling),
         refresh_access when refresh_access in [:none, :when_supported] <-
           refresh_access(Map.get(value, "refresh_access", "none")),
         authorization_timeout_ms
         when authorization_timeout_ms in 1..@max_authorization_timeout_ms <-
           Map.get(value, "authorization_timeout_ms", 300_000),
         unknown_expiry_ttl_ms
         when unknown_expiry_ttl_ms in 1..@max_unknown_expiry_ttl_ms <-
           Map.get(value, "unknown_expiry_ttl_ms", 300_000),
         {:ok, additional_origins, private_network_origins} <-
           network(Map.get(value, "network", %{})),
         {:ok, client} <- client(value["client"], credential_names),
         {:ok, fingerprint} <-
           fingerprint(%{
             installation_id: installation_id,
             issuer: issuer,
             resource: configured_resource,
             scope_ceiling: scope_ceiling,
             default_scopes: default_scopes,
             refresh_access: refresh_access,
             authorization_timeout_ms: authorization_timeout_ms,
             unknown_expiry_ttl_ms: unknown_expiry_ttl_ms,
             additional_origins: additional_origins,
             private_network_origins: private_network_origins,
             client: client
           }) do
      {:ok,
       %__MODULE__{
         installation_id: installation_id,
         issuer: issuer,
         resource: configured_resource,
         scope_ceiling: scope_ceiling,
         default_scopes: default_scopes,
         refresh_access: refresh_access,
         authorization_timeout_ms: authorization_timeout_ms,
         unknown_expiry_ttl_ms: unknown_expiry_ttl_ms,
         additional_origins: additional_origins,
         private_network_origins: private_network_origins,
         client: client,
         fingerprint: fingerprint
       }}
    else
      _invalid -> {:error, :invalid_oauth_authority}
    end
  end

  def from_host(_value, _endpoint, _credential_names, _opts),
    do: {:error, :invalid_oauth_authority}

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = authority) do
    credentials =
      case authority.client do
        %{client_secret_binding: binding} when is_binary(binding) -> MapSet.new([binding])
        _client -> MapSet.new()
      end

    case from_host(authority_document(authority), authority.resource, credentials,
           allow_insecure_loopback: true
         ) do
      {:ok, rebuilt} -> rebuilt == authority
      _invalid -> false
    end
  rescue
    _exception -> false
  end

  def valid?(_authority), do: false

  @doc """
  Validates and retains one exact HTTPS issuer identifier.

  Tests and trusted local embeddings may explicitly admit an HTTP
  literal-loopback issuer with `allow_insecure_loopback: true`; host
  configuration never enables that exception.
  """
  @spec issuer(term(), keyword()) :: {:ok, binary()} | {:error, :invalid_issuer}
  def issuer(value, opts \\ [])

  def issuer(value, opts) when is_binary(value) and is_list(opts) do
    allow_insecure_loopback = Keyword.get(opts, :allow_insecure_loopback, false)

    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil} ->
        if MCPEndpoint.origin_allowed?(scheme, host, allow_insecure_loopback) and
             byte_size(value) <= 4_096 and String.valid?(value) and
             Keyword.keys(opts) -- [:allow_insecure_loopback] == [],
           do: {:ok, value},
           else: {:error, :invalid_issuer}

      _invalid ->
        {:error, :invalid_issuer}
    end
  end

  def issuer(_value, _opts), do: {:error, :invalid_issuer}

  @doc """
  Canonicalizes only scheme and host case for one HTTPS MCP resource.

  Path bytes, explicit port spelling, trailing slash, and query bytes remain
  significant. Tests and trusted local embeddings may explicitly admit an HTTP
  literal-loopback resource with `allow_insecure_loopback: true`; host
  configuration never enables that exception.
  """
  @spec resource(term(), keyword()) :: {:ok, binary()} | {:error, :invalid_resource}
  def resource(value, opts \\ [])

  def resource(value, opts) when is_binary(value) and is_list(opts) do
    allow_insecure_loopback = Keyword.get(opts, :allow_insecure_loopback, false)

    case URI.parse(value) do
      %URI{
        authority: authority,
        host: host,
        userinfo: nil,
        fragment: nil
      } = uri
      when is_binary(authority) and is_binary(host) and host != "" ->
        canonical_resource(value, opts, allow_insecure_loopback, uri)

      _invalid ->
        {:error, :invalid_resource}
    end
  end

  def resource(_value, _opts), do: {:error, :invalid_resource}

  defp canonical_resource(value, opts, allow_insecure_loopback, uri) do
    with true <- MCPEndpoint.origin_allowed?(uri.scheme, uri.host, allow_insecure_loopback),
         true <- byte_size(value) <= 4_096 and String.valid?(value),
         true <- Keyword.keys(opts) -- [:allow_insecure_loopback] == [] do
      canonical_host = canonical_host(uri.host)

      explicit_port =
        if explicit_port?(uri.authority, uri.port), do: ":#{uri.port}", else: ""

      path = uri.path || ""
      query = if is_nil(uri.query), do: "", else: "?" <> uri.query
      {:ok, uri.scheme <> "://" <> canonical_host <> explicit_port <> path <> query}
    else
      false -> {:error, :invalid_resource}
    end
  end

  @doc "Returns whether this authority can use the CLI loopback interaction."
  @spec cli_compatible?(t()) :: boolean()
  def cli_compatible?(%__MODULE__{
        client: %{
          registration: registration,
          token_endpoint_auth_method: :none,
          redirect: {:loopback, _redirect}
        }
      })
      when registration in [:pre_registered, :client_id_metadata_document],
      do: true

  def cli_compatible?(_authority), do: false

  defp optional_resource(nil, endpoint_resource, _opts), do: {:ok, endpoint_resource}
  defp optional_resource(value, _endpoint_resource, opts), do: resource(value, opts)

  defp refresh_access("none"), do: :none
  defp refresh_access("when_supported"), do: :when_supported
  defp refresh_access(_value), do: :invalid

  defp network(value) when is_map(value) do
    with :ok <-
           exact_keys(value, ~w(additional_origins private_network_origins), []),
         {:ok, additional} <-
           origins(Map.get(value, "additional_origins", []), :https_only),
         {:ok, private} <-
           origins(Map.get(value, "private_network_origins", []), :http_or_https) do
      {:ok, additional, private}
    end
  end

  defp network(_value), do: {:error, :invalid_network}

  defp origins(values, mode)
       when is_list(values) and length(values) <= @max_origins do
    with true <- values == Enum.uniq(values),
         true <- Enum.all?(values, &valid_origin?(&1, mode)) do
      {:ok, Enum.sort(values)}
    else
      _invalid -> {:error, :invalid_network}
    end
  end

  defp origins(_values, _mode), do: {:error, :invalid_network}

  defp valid_origin?(value, mode) when is_binary(value) do
    case URI.parse(value) do
      %URI{
        scheme: scheme,
        authority: authority,
        host: host,
        path: path,
        query: nil,
        fragment: nil,
        userinfo: nil
      }
      when is_binary(authority) and is_binary(host) and host != "" and path in [nil, "", "/"] ->
        scheme == "https" or (mode == :http_or_https and scheme == "http")

      _invalid ->
        false
    end
  end

  defp valid_origin?(_value, _mode), do: false

  defp client(value, credential_names) when is_map(value) do
    registration = Map.get(value, "registration")

    case registration do
      "pre_registered" -> pre_registered_client(value, credential_names)
      "client_id_metadata_document" -> metadata_document_client(value)
      _unsupported -> {:error, :invalid_client}
    end
  end

  defp client(_value, _credential_names), do: {:error, :invalid_client}

  defp pre_registered_client(value, credential_names) do
    allowed =
      ~w(
        registration client_id token_endpoint_auth_method
        client_secret_binding grant_types redirect_uris loopback_redirect
      )

    with :ok <-
           exact_keys(
             value,
             allowed,
             ~w(registration client_id token_endpoint_auth_method grant_types)
           ),
         client_id when is_binary(client_id) <- value["client_id"],
         true <- bounded_opaque?(client_id, @max_client_id_bytes),
         {:ok, method, secret_binding} <-
           authentication(
             value["token_endpoint_auth_method"],
             Map.get(value, "client_secret_binding"),
             credential_names
           ),
         {:ok, grant_types} <- grant_types(value["grant_types"]),
         {:ok, redirect} <- redirect(value, method) do
      client = %{
        registration: :pre_registered,
        client_id: client_id,
        token_endpoint_auth_method: method,
        grant_types: grant_types,
        redirect: redirect
      }

      {:ok, maybe_put_secret_binding(client, secret_binding)}
    end
  end

  defp metadata_document_client(value) do
    allowed =
      ~w(
        registration client_id token_endpoint_auth_method
        redirect_uris loopback_redirect
      )

    with :ok <-
           exact_keys(
             value,
             allowed,
             ~w(registration client_id token_endpoint_auth_method)
           ),
         "none" <- value["token_endpoint_auth_method"],
         client_id when is_binary(client_id) <- value["client_id"],
         true <- bounded_opaque?(client_id, @max_client_id_bytes),
         :ok <- client_metadata_url(client_id),
         {:ok, redirect} <- redirect(value, :none) do
      {:ok,
       %{
         registration: :client_id_metadata_document,
         client_id: client_id,
         token_endpoint_auth_method: :none,
         grant_types: MapSet.new(["authorization_code"]),
         redirect: redirect
       }}
    end
  end

  defp authentication("none", nil, _credential_names), do: {:ok, :none, nil}

  defp authentication("client_secret_basic", binding, credential_names)
       when is_binary(binding) do
    if MapSet.member?(credential_names, binding),
      do: {:ok, :client_secret_basic, binding},
      else: {:error, :invalid_client}
  end

  defp authentication(_method, _binding, _credential_names),
    do: {:error, :invalid_client}

  defp grant_types(values) when is_list(values) and length(values) in 1..2 do
    allowed = ["authorization_code", "refresh_token"]

    if values == Enum.uniq(values) and Enum.all?(values, &(&1 in allowed)) and
         "authorization_code" in values do
      {:ok, MapSet.new(values)}
    else
      {:error, :invalid_client}
    end
  end

  defp grant_types(_values), do: {:error, :invalid_client}

  defp redirect(value, method) do
    redirect_uris = Map.get(value, "redirect_uris")
    loopback = Map.get(value, "loopback_redirect")

    case {redirect_uris, loopback, method} do
      {values, nil, _method} when is_list(values) ->
        https_redirects(values)

      {nil, descriptor, :none} when is_map(descriptor) ->
        loopback_redirect(descriptor)

      _invalid ->
        {:error, :invalid_redirect}
    end
  end

  defp https_redirects(values)
       when length(values) in 1..@max_redirects do
    if values == Enum.uniq(values) and Enum.all?(values, &valid_https_redirect?/1),
      do: {:ok, {:https, values}},
      else: {:error, :invalid_redirect}
  end

  defp https_redirects(_values), do: {:error, :invalid_redirect}

  defp valid_https_redirect?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        path: path,
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when is_binary(host) and host != "" and is_binary(path) and path != "" ->
        byte_size(value) <= 4_096 and String.valid?(value) and
          String.starts_with?(value, "https://")

      _invalid ->
        false
    end
  end

  defp valid_https_redirect?(_value), do: false

  defp loopback_redirect(value) do
    with :ok <- exact_keys(value, ~w(host path), ~w(host path)),
         host when host in ["127.0.0.1", "::1"] <- value["host"],
         path when is_binary(path) <- value["path"],
         true <-
           byte_size(path) in 1..1_024 and String.valid?(path) and
             String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
             not String.contains?(path, ["?", "#"]) do
      {:ok, {:loopback, %{host: host, path: path}}}
    else
      _invalid -> {:error, :invalid_redirect}
    end
  end

  defp client_metadata_url(value) do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        path: path,
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when is_binary(host) and host != "" and is_binary(path) and path not in ["", "/"] ->
        segments = :binary.split(path, "/", [:global])

        if String.starts_with?(value, "https://") and
             Enum.all?(segments, &(&1 not in [".", ".."])) do
          :ok
        else
          {:error, :invalid_client}
        end

      _invalid ->
        {:error, :invalid_client}
    end
  end

  defp fingerprint(authority) do
    projection = %{
      "version" => 1,
      "installation_id" => authority.installation_id,
      "issuer" => authority.issuer,
      "resource" => authority.resource,
      "scope_ceiling" => sorted_scopes(authority.scope_ceiling),
      "default_scopes" => sorted_scopes(authority.default_scopes),
      "refresh_access" => Atom.to_string(authority.refresh_access),
      "authorization_timeout_ms" => authority.authorization_timeout_ms,
      "unknown_expiry_ttl_ms" => authority.unknown_expiry_ttl_ms,
      "additional_origins" => authority.additional_origins,
      "private_network_origins" => authority.private_network_origins,
      "client" => client_projection(authority.client)
    }

    with {:ok, encoded} <- DeterministicJSON.encode(projection) do
      {:ok, "v1:" <> Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)}
    end
  end

  defp client_projection(client) do
    %{
      "registration" => Atom.to_string(client.registration),
      "client_id" => client.client_id,
      "token_endpoint_auth_method" => Atom.to_string(client.token_endpoint_auth_method),
      "grant_types" => sorted_scopes(client.grant_types),
      "client_secret_binding" => Map.get(client, :client_secret_binding),
      "redirect" => redirect_projection(client.redirect)
    }
  end

  defp authority_document(authority) do
    %{
      "installation_id" => authority.installation_id,
      "issuer" => authority.issuer,
      "resource" => authority.resource,
      "scope_ceiling" => sorted_scopes(authority.scope_ceiling),
      "default_scopes" => sorted_scopes(authority.default_scopes),
      "refresh_access" => Atom.to_string(authority.refresh_access),
      "authorization_timeout_ms" => authority.authorization_timeout_ms,
      "unknown_expiry_ttl_ms" => authority.unknown_expiry_ttl_ms,
      "network" => %{
        "additional_origins" => authority.additional_origins,
        "private_network_origins" => authority.private_network_origins
      },
      "client" => client_document(authority.client)
    }
  end

  defp client_document(%{registration: :pre_registered} = client) do
    %{
      "registration" => "pre_registered",
      "client_id" => client.client_id,
      "token_endpoint_auth_method" => Atom.to_string(client.token_endpoint_auth_method),
      "grant_types" => sorted_scopes(client.grant_types)
    }
    |> maybe_put_client_secret_binding(client)
    |> put_redirect(client.redirect)
  end

  defp client_document(%{registration: :client_id_metadata_document} = client) do
    %{
      "registration" => "client_id_metadata_document",
      "client_id" => client.client_id,
      "token_endpoint_auth_method" => "none"
    }
    |> put_redirect(client.redirect)
  end

  defp maybe_put_client_secret_binding(document, %{client_secret_binding: binding}),
    do: Map.put(document, "client_secret_binding", binding)

  defp maybe_put_client_secret_binding(document, _client), do: document

  defp put_redirect(document, {:loopback, redirect}) do
    Map.put(document, "loopback_redirect", %{
      "host" => redirect.host,
      "path" => redirect.path
    })
  end

  defp put_redirect(document, {:https, redirect_uris}),
    do: Map.put(document, "redirect_uris", redirect_uris)

  defp redirect_projection({:https, values}),
    do: %{"type" => "https", "uris" => values}

  defp redirect_projection({:loopback, value}),
    do: %{"type" => "loopback", "host" => value.host, "path" => value.path}

  defp sorted_scopes(scopes), do: scopes |> MapSet.to_list() |> Enum.sort()

  defp maybe_put_secret_binding(client, nil), do: client

  defp maybe_put_secret_binding(client, binding),
    do: Map.put(client, :client_secret_binding, binding)

  defp canonical_host(host) do
    host = String.downcase(host)
    if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
  end

  defp explicit_port?(authority, port) do
    String.ends_with?(authority, ":" <> Integer.to_string(port))
  end

  defp bounded_opaque?(value, max_bytes),
    do:
      is_binary(value) and byte_size(value) in 1..max_bytes and String.valid?(value) and
        not String.contains?(value, [<<0>>, "\r", "\n"])

  defp exact_keys(value, allowed, required) do
    keys = Map.keys(value)

    if Enum.all?(keys, &is_binary/1) and keys -- allowed == [] and required -- keys == [],
      do: :ok,
      else: {:error, :invalid_keys}
  end
end
