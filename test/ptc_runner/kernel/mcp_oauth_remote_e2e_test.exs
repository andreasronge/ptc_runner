defmodule PtcRunner.Kernel.MCPOAuthRemoteE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  Exercises explicit OAuth authorization and dynamic bearer issuance against
  the pinned official Go SDK Streamable HTTP server.

  The deterministic credential-free Go harness serves discovery,
  authorization, S256-bound code exchange, short-lived tokens, rotating
  refresh tokens, and the protected independently maintained MCP protocol
  implementation over a real literal-loopback HTTPS boundary.
  """

  @moduletag :e2e
  @moduletag timeout: 120_000

  unless System.get_env("PTC_TEST_MCP_OAUTH") == "1" and
           System.get_env("PTC_TEST_MCP_TLS") == "1" do
    @moduletag skip: "requires the OAuth- and TLS-enabled Go MCP harness"
  end

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.CommandEngine
  alias PtcRunner.Kernel.CommandEntry
  alias PtcRunner.Kernel.CommandOutcome
  alias PtcRunner.Kernel.CommandRuntime
  alias PtcRunner.Kernel.Deadline
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MCPHTTPAdapter
  alias PtcRunner.Kernel.MCPOAuth.Authority
  alias PtcRunner.Kernel.MCPOAuth.Authorization
  alias PtcRunner.Kernel.MCPOAuth.Context
  alias PtcRunner.Kernel.MCPOAuth.Store
  alias PtcRunner.Kernel.MCPOAuth.Store.Memory
  alias PtcRunner.Kernel.MCPOAuth.TokenManager
  alias PtcRunner.Kernel.MCPSource
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  setup_all do
    ca_file = System.fetch_env!("PTC_TEST_MCP_CA_FILE")
    assert :ok = :public_key.cacerts_load(String.to_charlist(ca_file))
    on_exit(fn -> :public_key.cacerts_clear() end)
    :ok
  end

  @tag :tmp_dir
  test "a host document authorizes and runs through the Mix command boundary", %{tmp_dir: dir} do
    endpoint = System.fetch_env!("PTC_TEST_MCP_2026_ENDPOINT")
    assert URI.parse(endpoint).scheme == "https"

    {application, host} = write_command_fixture(dir, endpoint)
    parent = self()

    assert {:ok, runtime} =
             CommandRuntime.new(
               provider_application_mode: :host_owned,
               authorization_targets: ["workspace"],
               authorization_notifier: &visit_remote_authorization(parent, &1)
             )

    assert {:ok, entry} =
             CommandEntry.open(
               ["run", application, "--host-config", host, "--authorize-mcp", "workspace"],
               :mix
             )

    assert {:ok, %CommandOutcome{} = outcome, nil} =
             CommandEngine.dispatch_frontend_entry(entry, runtime)

    assert outcome.envelope["status"] == "ok"
    assert outcome.envelope["execution"]["outcome"] == "ok"
    assert_receive {:authorization_notice, authorization_url}, 5_000
    assert URI.parse(authorization_url).scheme == "https"

    assert %{"outcome" => "returned", "value" => value} =
             outcome.envelope["result"]["value"]

    assert %{"status" => "ok", "value" => %{"text" => [entry | _]}} = value
    assert is_binary(entry) and entry != ""
  end

  test "an explicitly authorized bearer crosses the real MCP protocol boundary" do
    endpoint = System.fetch_env!("PTC_TEST_MCP_2026_ENDPOINT")
    starting_stats = oauth_stats(endpoint)
    authority = authority(endpoint)

    {:ok, memory} = Memory.start(owner: self())
    {:ok, store} = Memory.store(memory)

    {:ok, context} =
      Context.new(
        tenant_id: "e2e",
        principal_id: "operator",
        store: store,
        deadline: Deadline.new(1_000)
      )

    {:ok, claims} =
      Store.claim_authorities(
        store,
        context.tenant_id,
        [{authority.installation_id, authority.fingerprint}],
        Deadline.new(1_000)
      )

    authority_epoch = claims[authority.installation_id]
    redirect_uri = "http://127.0.0.1:49152/callback"

    {:ok, pending} =
      Authorization.begin_authorization(context, authority,
        authority_epoch: authority_epoch,
        redirect_uri: redirect_uri
      )

    authorization_query =
      pending.url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    assert {:ok, %{status: 302} = authorization_response} =
             MCPHTTPAdapter.request(
               method: :get,
               url: pending.url,
               timeout_ms: 5_000
             )

    [callback_location] =
      MCPHTTPAdapter.get_header(authorization_response, "location")

    callback_query =
      callback_location
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.query_decoder()
      |> Enum.to_list()

    {:ok, _grant} =
      Authorization.complete_authorization(
        context,
        pending,
        callback_query,
        []
      )

    assert callback_query |> Map.new() |> Map.fetch!("state") == authorization_query["state"]

    {:ok, manager} =
      TokenManager.start(
        owner: self(),
        context: context,
        authority: authority,
        authority_epoch: authority_epoch
      )

    on_exit(fn -> TokenManager.close(manager) end)

    builder =
      MCPSource.builder(
        transport: {:streamable_http, endpoint: endpoint, authorization: manager},
        tools: %{"cityTime" => %{as: "time.city", effect: :read}},
        timeout_ms: 30_000,
        max_result_bytes: 500_000
      )

    {:ok, registry} = ProviderRegistry.new(%{"oauth-remote" => builder})

    {:ok, limits} =
      Limits.new(
        run_duration_ms: 90_000,
        workflow_timeout_ms: 90_000,
        evaluation_timeout_ms: 30_000
      )

    {:ok, %{capabilities: [capability], close: close}} =
      ProviderRegistry.build(
        registry,
        "oauth-remote",
        %{"allow" => ["time.city"]},
        %{
          application_content_digest: String.duplicate("0", 64),
          destination: :mission,
          limits: limits,
          installed_limits: limits,
          owner: self()
        }
      )

    if is_function(close, 0), do: on_exit(close)

    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new(capabilities: [capability])
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "mcp-oauth-remote-e2e")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    source =
      ~S|(return (tool/kernel-eval {"mission" "default" "kind" :source "source" "(return (tool/time.city {\"city\" \"nyc\"}))"}))|

    assert {:ok,
            %{
              value: %{
                "status" => "ok",
                "value" => %{"outcome" => "returned", "value" => value}
              }
            }} =
             Kernel.run(source, config)

    assert %{"status" => "ok", "value" => %{"text" => [entry | _]}} = value
    assert is_binary(entry) and entry != ""

    deadline_ms = System.monotonic_time(:millisecond) + 30_000
    assert {:ok, issued} = TokenManager.authorization_header(manager, deadline_ms)
    assert {"authorization", "Bearer oauth-e2e-access-" <> rotated_generation} = issued.header
    assert String.to_integer(rotated_generation) > 1
    assert :ok = TokenManager.release(manager, issued.admission, deadline_ms)

    stats = oauth_stats(endpoint)
    assert stats["authorization"] == starting_stats["authorization"] + 1
    assert stats["code_exchange"] == starting_stats["code_exchange"] + 1
    assert stats["refresh"] > starting_stats["refresh"]
    assert stats["mcp_calls"] > starting_stats["mcp_calls"]
    assert stats["directed"] == starting_stats["directed"] + 1
    assert stats["fallback"] > starting_stats["fallback"]
  end

  defp authority(endpoint) do
    private_origin =
      endpoint
      |> URI.parse()
      |> then(fn uri -> "#{uri.scheme}://#{uri.host}:#{uri.port}" end)

    {:ok, authority} =
      Authority.from_host(
        %{
          "installation_id" => "oauth-e2e",
          "issuer" => endpoint <> "/oauth",
          "scope_ceiling" => ["read", "offline_access"],
          "default_scopes" => ["read"],
          "refresh_access" => "when_supported",
          "network" => %{
            "additional_origins" => [],
            "private_network_origins" => [private_origin]
          },
          "client" => %{
            "registration" => "pre_registered",
            "client_id" => "ptc-oauth-e2e",
            "token_endpoint_auth_method" => "none",
            "grant_types" => ["authorization_code", "refresh_token"],
            "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
          }
        },
        endpoint,
        MapSet.new(),
        allow_insecure_loopback: false
      )

    authority
  end

  defp oauth_stats(endpoint) do
    assert {:ok, %{status: 200, body: body}} =
             MCPHTTPAdapter.request(
               method: :get,
               url: endpoint <> "/oauth/stats",
               timeout_ms: 5_000
             )

    Jason.decode!(body)
  end

  defp write_command_fixture(dir, endpoint) do
    host = Path.join(dir, "ptc-host.json")
    application = Path.join(dir, "ptc.json")

    File.write!(
      host,
      Jason.encode!(%{
        "install" => %{
          "workspace" => %{
            "source" => "mcp",
            "installation_revision" => "workspace-oauth-v1",
            "transport" => %{
              "type" => "streamable_http",
              "endpoint" => endpoint,
              "oauth" => oauth_host_block(endpoint)
            },
            "ceilings" => %{"timeout_ms" => 30_000},
            "tools" => %{
              "cityTime" => %{"as" => "workspace.city_time", "effect" => "read"}
            }
          }
        }
      })
    )

    File.write!(
      application,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [
            %{"id" => "main", "path" => "main.clj", "dependencies" => ["kernel"]},
            %{"library" => "kernel"}
          ],
          "entry" => "main/run"
        },
        "input" => %{"value" => %{"city" => "nyc"}},
        "limits" => %{"evaluation_timeout_ms" => 30_000},
        "providers" => %{
          "mission" => [
            %{"name" => "workspace", "config" => %{"allow" => ["workspace.city_time"]}}
          ]
        },
        "missions" => %{
          "default" => %{
            "components" => [%{"id" => "clock", "path" => "clock.clj"}],
            "providers" => ["workspace"]
          }
        }
      })
    )

    File.write!(
      Path.join(dir, "main.clj"),
      ~S|(ns main "OAuth command E2E workflow." {:visibility :prompt})
(defn run [input]
  (return (kernel/eval-source "default"
            (str "(clock/city-time \"" (get input "city") "\")"))))|
    )

    File.write!(
      Path.join(dir, "clock.clj"),
      ~S|(ns clock "OAuth command E2E mission." {:visibility :prompt})
(defn city-time [city]
  (return (tool/workspace.city_time {"city" city})))|
    )

    {application, host}
  end

  defp oauth_host_block(endpoint) do
    uri = URI.parse(endpoint)
    origin = "#{uri.scheme}://#{uri.host}:#{uri.port}"

    %{
      "installation_id" => "workspace-oauth",
      "issuer" => endpoint <> "/oauth",
      "resource" => endpoint,
      "scope_ceiling" => ["read", "offline_access"],
      "default_scopes" => ["read"],
      "refresh_access" => "when_supported",
      "network" => %{"private_network_origins" => [origin]},
      "client" => %{
        "registration" => "pre_registered",
        "client_id" => "ptc-oauth-e2e",
        "token_endpoint_auth_method" => "none",
        "grant_types" => ["authorization_code", "refresh_token"],
        "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
      }
    }
  end

  defp visit_remote_authorization(parent, url) do
    with {:ok, %{status: 302} = response} <-
           MCPHTTPAdapter.request(method: :get, url: url, timeout_ms: 5_000),
         [callback] <- MCPHTTPAdapter.get_header(response, "location") do
      send(parent, {:authorization_notice, url})

      spawn(fn -> get_loopback_callback(callback) end)

      :ok
    else
      failure -> raise "authorization fixture failed: #{inspect(failure)}"
    end
  end

  defp get_loopback_callback(url) do
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
end
