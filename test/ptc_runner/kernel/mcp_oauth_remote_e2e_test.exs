defmodule PtcRunner.Kernel.MCPOAuthRemoteE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  Exercises explicit OAuth authorization and dynamic bearer issuance against
  the pinned official Go SDK Streamable HTTP server.

  The deterministic credential-free Go harness serves discovery,
  authorization, S256-bound code exchange, short-lived tokens, rotating
  refresh tokens, and the protected independently maintained MCP protocol
  implementation over a real literal-loopback HTTP boundary.
  """

  @moduletag :e2e
  @moduletag timeout: 120_000

  unless System.get_env("PTC_TEST_MCP_OAUTH") == "1" do
    @moduletag skip: "requires the OAuth-enabled Go MCP harness"
  end

  alias PtcRunner.Kernel
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

  test "an explicitly authorized bearer crosses the real MCP protocol boundary" do
    endpoint = System.fetch_env!("PTC_TEST_MCP_2026_ENDPOINT")
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
        transport:
          {:streamable_http,
           endpoint: endpoint, authorization: manager, allow_insecure_loopback: true},
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

    assert {:ok, %{status: 200, body: stats_body}} =
             MCPHTTPAdapter.request(
               method: :get,
               url: endpoint <> "/oauth/stats",
               timeout_ms: 5_000
             )

    stats = Jason.decode!(stats_body)
    assert stats["authorization"] == 1
    assert stats["code_exchange"] == 1
    assert stats["refresh"] > 0
    assert stats["mcp_calls"] > 0
    assert stats["directed"] == 1
    assert stats["fallback"] > 0
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
        allow_insecure_loopback: true
      )

    authority
  end
end
