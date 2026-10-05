defmodule PtcRunner.TestSupport.WarmMCPFixture do
  @moduledoc false
  alias PtcRunner.Kernel.{
    HostConfig,
    HostInstallation,
    InstallationCatalog,
    ProviderRuntime,
    ServingTemplate
  }

  alias PtcRunner.TestSupport.MCPHTTPFixture

  def http(opts \\ []) do
    observer = self()

    MCPHTTPFixture.start(fn request ->
      body = request.body
      send(observer, {:upstream, body["method"], request.headers})

      result =
        case body["method"] do
          "server/discover" ->
            %{
              "resultType" => "complete",
              "supportedVersions" => ["2026-07-28"],
              "capabilities" => %{"tools" => %{}},
              "ttlMs" => 0,
              "cacheScope" => "private"
            }

          "tools/list" ->
            %{
              "resultType" => "complete",
              "ttlMs" => 0,
              "cacheScope" => "private",
              "tools" => [
                %{
                  "name" => "echo",
                  "inputSchema" => %{
                    "type" => "object",
                    "properties" => %{"query" => %{"type" => "string"}}
                  }
                }
              ]
            }

          "tools/call" ->
            if opts[:on_call], do: opts[:on_call].(request)

            %{
              "resultType" => "complete",
              "content" => [%{"type" => "text", "text" => body["params"]["arguments"]["query"]}]
            }
        end

      {200, [{"content-type", "application/json"}],
       Jason.encode!(%{"jsonrpc" => "2.0", "id" => body["id"], "result" => result})}
    end)
  end

  def http_transport(endpoint),
    do: %{"type" => "streamable_http", "endpoint" => endpoint, "allow_insecure_loopback" => true}

  def pins(template, services) do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        {:ok, runtime} =
          ProviderRuntime.start_link(template: template, services: services, pins: :discover)

        GenServer.stop(runtime)
      end)

    Jason.decode!(output)
  end

  def application(dir, transport, opts \\ []) do
    File.write!(
      Path.join(dir, "main.clj"),
      Keyword.get(opts, :source, "(ns app) (defn run {:effect :write} [input] (return input))")
    )

    File.write!(
      Path.join(dir, "schema.json"),
      Jason.encode!(Keyword.get(opts, :schema, %{"type" => "object"}))
    )

    path = Path.join(dir, "app.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{
          "components" => [%{"id" => "app", "path" => "main.clj"}],
          "entry" => "app/run"
        },
        "input" => %{"value" => %{}},
        "missions" => %{"default" => %{"components" => [], "providers" => ["remote"]}},
        "providers" => %{
          "mission" => [%{"name" => "remote", "config" => %{"allow" => ["remote.echo"]}}]
        },
        "contracts" => %{
          "input_schema" => %{"path" => "schema.json"},
          "result_schema" => %{"path" => "schema.json"}
        }
      })
    )

    host_document = %{
      "limits" => Keyword.get(opts, :host_limits, %{}),
      "credentials" => %{
        "gateway" => %{"file" => "gateway.key"},
        "upstream" => %{"file" => "upstream.key"}
      },
      "install" => %{
        "remote" => %{
          "source" => "mcp",
          "installation_revision" => "v1",
          "transport" => transport,
          "tools" => %{
            Keyword.get(opts, :upstream_tool, "echo") => %{
              "as" => "remote.echo",
              "effect" => "read"
            }
          }
        }
      }
    }

    File.write!(Path.join(dir, "gateway.key"), String.duplicate("a", 32))
    File.write!(Path.join(dir, "upstream.key"), "fixture-key")
    host_path = Path.join(dir, "host.json")
    File.write!(host_path, Jason.encode!(host_document))
    {:ok, host} = HostConfig.load(host_path)
    {:ok, catalog} = HostInstallation.catalog(host)
    ExUnit.Callbacks.on_exit(fn -> InstallationCatalog.close(catalog) end)
    {:ok, services} = HostInstallation.runtime_services(host)
    {:ok, template} = ServingTemplate.from_directory(path, host.limits, providers: catalog)
    {template, services}
  end
end
