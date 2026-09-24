defmodule PtcRunner.TestSupport.ProviderExecutionOAuthFixtures do
  @moduledoc false

  # Shared by ProviderExecutionOAuthTest (async) and ProviderExecutionOAuthGlobalStateTest: a
  # loopback OAuth-protected MCP server and the prepared runs that select it.

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.Attestation
  alias PtcRunner.Kernel.ExecutionSessionOwner
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InstallationCatalog
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.ProviderExecution
  alias PtcRunner.Kernel.ProviderRuntimeServices
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.TestSupport.MCPHTTPFixture

  # Starts an execution owner from a spawned caller whose OAuth notifier blocks
  # forever, and reports the owner and its eventual result to `parent`.
  def spawn_blocked_caller(parent, fixture) do
    spawn(fn ->
      {:ok, owner} =
        ExecutionSessionOwner.start(
          fixture.prepared,
          fixture.authority,
          self(),
          fixture.execution,
          fn url ->
            send(parent, {:blocked_in_notifier, url})
            receive do: (:never -> :never)
          end
        )

      send(parent, {:execution_owner, owner})
      send(parent, {:execution_result, ExecutionSessionOwner.await(owner)})
    end)
  end

  def provider_fixture(server, names \\ ["fixture"], opts \\ []) do
    installed = Keyword.get(opts, :installed, names)
    credential_alias = Keyword.get(opts, :credential_alias)
    provider_config = Keyword.get(opts, :provider_config, %{})
    host = host(server, installed, opts)
    {:ok, catalog} = HostInstallation.catalog(host)

    {:ok, services} =
      HostInstallation.runtime_services(host,
        provider_application_mode: Keyword.get(opts, :provider_application_mode, :host_owned)
      )

    services = maybe_delay_activation(services, opts)

    {:ok, execution} =
      ProviderExecution.new(catalog, services, Keyword.get(opts, :authorize, names))

    {:ok, authority} = PublicationAuthority.new([])

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "main.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"value" => %{}},
      "providers" => %{
        "workflow" =>
          names
          |> Enum.filter(&(&1 == credential_alias))
          |> Enum.map(&%{"name" => &1, "config" => provider_config}),
        "mission" =>
          names
          |> Enum.reject(&(&1 == credential_alias))
          |> Enum.map(&%{"name" => &1, "config" => provider_config})
      }
    }

    documents = %{
      "ptc.json" => Jason.encode!(manifest),
      "main.clj" => "(ns app) (defn run [_input] (return {\"answer\" 42}))"
    }

    {:ok, request} =
      ApplicationPackage.request_memory("ptc.json", documents, result_projection: :json)

    {:ok, prepared} = RunCoordinator.prepare(request, catalog)
    on_exit(fn -> InstallationCatalog.close(catalog) end)

    %{prepared: prepared, catalog: catalog, execution: execution, authority: authority}
  end

  # Host configuration deliberately refuses insecure loopback OAuth, so the
  # fixture decodes a normal HTTPS installation and then rebinds only the
  # transport endpoint and authority to the loopback server under test.
  defp host(server, names, opts) do
    {:ok, decoded} = HostConfig.decode(host_document(names, opts), "/tmp")

    install =
      Map.new(decoded.install, fn {name, installation} ->
        if installation.source == :mcp do
          transport = %{
            installation.transport
            | endpoint: server.endpoint,
              oauth: authority(server.base, name, opts)
          }

          {name, %{installation | transport: transport}}
        else
          {name, installation}
        end
      end)

    struct!(HostConfig,
      path: "/tmp/ptc-host.json",
      directory: "/tmp",
      runtime: decoded.runtime,
      limits: decoded.limits,
      credentials: decoded.credentials,
      install: install
    )
  end

  defp host_document(names, opts) do
    credential_alias = Keyword.get(opts, :credential_alias)
    credential_env = Keyword.get(opts, :credential_env)

    document = %{
      "install" =>
        Map.new(names, fn name ->
          installation =
            if name == credential_alias,
              do: credentialed_installation_document(),
              else: installation_document(name, opts)

          {name, installation}
        end)
    }

    if credential_alias,
      do: Map.put(document, "credentials", %{"missing" => %{"env" => credential_env}}),
      else: document
  end

  defp credentialed_installation_document do
    %{
      "source" => "llm",
      "structured_output_mode" => "unsupported",
      "usage_guarantees" => %{"tokens" => false, "cost_currency" => nil},
      "installation_revision" => "credentialed-v1",
      "model" => "openrouter:deepseek/deepseek-v4-flash-0731",
      "credential" => "missing"
    }
  end

  defp installation_document(name, opts) do
    %{
      "source" => "mcp",
      "installation_revision" => "fixture-v1",
      "transport" => %{
        "type" => "streamable_http",
        "endpoint" => "https://mcp.example/mcp",
        "oauth" => %{
          "installation_id" => name <> "-primary",
          "issuer" => "https://auth.example",
          "scope_ceiling" => ["read"],
          "default_scopes" => ["read"],
          "authorization_timeout_ms" => Keyword.get(opts, :authorization_timeout_ms, 300_000),
          "client" => %{
            "registration" => "pre_registered",
            "client_id" => "fixture-client",
            "token_endpoint_auth_method" => "none",
            "grant_types" => ["authorization_code"],
            "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
          }
        }
      },
      "tools" => %{"echo" => %{"as" => name <> ".echo", "effect" => "read"}}
    }
  end

  defp maybe_delay_activation(services, opts) do
    case Keyword.get(opts, :activation_delay_ms) do
      nil ->
        services

      delay_ms ->
        original = services.activation
        label = Keyword.fetch!(opts, :activation_label)
        parent = self()

        activation = fn ->
          result = original.()
          send(parent, {:registry_activation_started, label})
          yield_until(System.monotonic_time(:millisecond) + delay_ms)
          result
        end

        reseal_services(%{services | activation: activation})
    end
  end

  defp reseal_services(services) do
    payload =
      {services.activation, services.credential_resolver, services.provider_application_mode,
       services.oauth_mode, services.provider_call_admission, services.runtime_binding,
       services.host_payload}

    %{services | attestation: Attestation.attest(ProviderRuntimeServices, payload)}
  end

  defp yield_until(deadline_ms) do
    if System.monotonic_time(:millisecond) < deadline_ms do
      :erlang.yield()
      yield_until(deadline_ms)
    end
  end

  # Stands in for the operator opening the one-time authorization URL: the
  # authorization server would redirect the browser to the loopback listener.
  def visit_authorization_url(parent, url) do
    query = URI.parse(url).query |> URI.decode_query()
    redirect = URI.parse(query["redirect_uri"])

    callback =
      URI.to_string(%{
        redirect
        | query:
            URI.encode_query(%{
              "code" => "fixture-code",
              "state" => query["state"],
              "iss" => query["resource"] |> issuer_of()
            })
      })

    send(parent, {:authorization_notice, url})
    spawn(fn -> get(callback) end)
    :ok
  end

  defp issuer_of(resource), do: resource

  defp get(url) do
    uri = URI.parse(url)
    path = uri.path <> "?" <> uri.query

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(uri.host), uri.port, [:binary, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        socket,
        "GET #{path} HTTP/1.1\r\nHost: #{uri.host}:#{uri.port}\r\nConnection: close\r\n\r\n"
      )

    _response = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
  end

  def authority(base, name \\ "fixture", opts \\ []) do
    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => name <> "-primary",
          "issuer" => base <> "/mcp",
          "scope_ceiling" => ["read"],
          "default_scopes" => ["read"],
          "authorization_timeout_ms" => Keyword.get(opts, :authorization_timeout_ms, 300_000),
          "network" => %{
            "additional_origins" => [],
            "private_network_origins" => [base]
          },
          "client" => %{
            "registration" => "pre_registered",
            "client_id" => "fixture-client",
            "token_endpoint_auth_method" => "none",
            "grant_types" => ["authorization_code"],
            "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
          }
        },
        base <> "/mcp",
        MapSet.new(),
        allow_insecure_loopback: true
      )

    authority
  end

  def start_server(opts \\ []) do
    parent = self()
    hold_token? = Keyword.get(opts, :hold_token?, false)

    fixture =
      MCPHTTPFixture.start(fn request ->
        send(parent, {:oauth_request, request.method, request.path})

        if hold_token? and request.path == "/token" do
          send(parent, {:token_pending, self()})
          receive do: (:release_token -> :ok)
        end

        respond(request)
      end)

    base = String.replace_suffix(fixture.endpoint, "/mcp", "")
    on_exit(fixture.close)
    %{base: base, endpoint: fixture.endpoint, close: fixture.close}
  end

  defp respond(%{method: "POST", path: "/mcp", headers: headers, body: body}) do
    if Map.has_key?(headers, "authorization") do
      mcp_response(body)
    else
      {401, [{"www-authenticate", ~s(Bearer scope="read")}], ""}
    end
  end

  defp respond(%{method: "GET", path: "/.well-known/oauth-protected-resource/mcp"} = request) do
    base = base_of(request)

    json(%{
      "resource" => base <> "/mcp",
      "authorization_servers" => [base <> "/mcp"],
      "scopes_supported" => ["read"]
    })
  end

  defp respond(%{method: "GET", path: "/.well-known/oauth-authorization-server/mcp"} = request) do
    base = base_of(request)

    json(%{
      "issuer" => base <> "/mcp",
      "authorization_endpoint" => base <> "/authorize",
      "token_endpoint" => base <> "/token",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code"],
      "response_modes_supported" => ["query"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["none"],
      "scopes_supported" => ["read"],
      "authorization_response_iss_parameter_supported" => true
    })
  end

  defp respond(%{method: "POST", path: "/token", body: body}) do
    form = URI.decode_query(body)

    if form["grant_type"] == "authorization_code" and form["code"] == "fixture-code" and
         is_binary(form["code_verifier"]) do
      json(%{
        "access_token" => "fixture-access-token",
        "token_type" => "Bearer",
        "expires_in" => 3_600,
        "scope" => "read"
      })
    else
      {400, [{"content-type", "application/json"}], ~s({"error":"invalid_grant"})}
    end
  end

  defp respond(_request), do: {404, [{"content-type", "application/json"}], "{}"}

  defp mcp_response(%{"method" => "server/discover", "id" => id}) do
    rpc(id, %{
      "resultType" => "complete",
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{"tools" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private"
    })
  end

  defp mcp_response(%{"method" => "tools/list", "id" => id}) do
    rpc(id, %{
      "resultType" => "complete",
      "tools" => [
        %{
          "name" => "echo",
          "description" => "Fixture tool.",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"query" => %{"type" => "string"}},
            "required" => ["query"]
          }
        }
      ],
      "ttlMs" => 0,
      "cacheScope" => "private"
    })
  end

  defp mcp_response(%{"id" => id}), do: rpc(id, %{"resultType" => "complete"})

  defp mcp_response(_body), do: {400, [{"content-type", "application/json"}], "{}"}

  defp rpc(id, result) do
    {200, [{"content-type", "application/json"}],
     Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})}
  end

  defp base_of(%{headers: %{"host" => host}}), do: "http://" <> host

  defp json(document) do
    {200, [{"content-type", "application/json"}, {"cache-control", "max-age=120"}],
     Jason.encode!(document)}
  end
end
