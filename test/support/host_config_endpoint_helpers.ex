defmodule PtcRunner.TestSupport.HostConfigEndpointHelpers do
  @moduledoc false

  import ExUnit.Assertions

  alias PtcRunner.Kernel.HostConfig

  def oauth_block do
    %{
      "installation_id" => "workspace",
      "issuer" => "https://issuer.example.test",
      "scope_ceiling" => ["read"],
      "client" => %{
        "registration" => "pre_registered",
        "client_id" => "client",
        "token_endpoint_auth_method" => "none",
        "grant_types" => ["authorization_code"],
        "loopback_redirect" => %{"host" => "127.0.0.1", "path" => "/callback"}
      }
    }
  end

  def config(endpoint, overrides \\ %{}) do
    transport =
      %{"type" => "streamable_http", "endpoint" => endpoint} |> Map.merge(overrides)

    %{
      "credentials" => %{"server_token" => %{"env" => "SERVER_TOKEN"}},
      "install" => %{
        "workspace" => %{
          "source" => "mcp",
          "installation_revision" => "workspace-v1",
          "transport" => transport,
          "tools" => %{"echo" => %{"as" => "workspace.echo", "effect" => "read"}}
        }
      }
    }
  end

  def mirror_overrides(loopback, credential) do
    if loopback,
      do: Map.put(credential, "allow_insecure_loopback", true),
      else: credential
  end

  def endpoint_diagnostic?(dir, document) do
    path = write(dir, document, "mirror-host.json")

    match?(
      {:error, {:installation_endpoint_invalid, _name, _reason}},
      HostConfig.load_command(path)
    )
  end

  def write(dir, config, name \\ "host.json") do
    path = Path.join(dir, name)
    File.write!(path, Jason.encode!(config))
    path
  end

  def unique_name,
    do: "host-#{System.unique_integer([:positive, :monotonic])}.json"

  def assert_refused(dir, endpoint, overrides \\ %{}) do
    path = write(dir, config(endpoint, overrides), unique_name())

    assert {:error, :invalid_host_config} = HostConfig.load(path)

    assert {:error, {:installation_endpoint_invalid, "workspace", _reason}} =
             HostConfig.load_command(path)
  end
end
