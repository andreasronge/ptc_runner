defmodule PtcGateway.TestSupport.GatewayFixture do
  @moduledoc """
  The minimal servable deployment every gateway test starts from.

  `fixture/2` writes a provider-free application, a host document binding one
  environment credential, and a gateway document serving that application under
  two tool names, then returns `{gateway_document_path, decoded_config}`. The
  caller writes the environment file and starts the gateway itself, because the
  anchoring rules under test differ per case.

  `response/3` and `mcp/4` are the well-formed HTTP and MCP clients. A case
  proving a rejection overrides exactly the one header, body or parameter it is
  about and inherits the rest, so what makes a request invalid stays visible in
  the case rather than in this module.
  """

  alias PtcRunner.Kernel.{Limits, ServingTemplate}

  @token String.duplicate("a", 32)

  @doc "The bearer value `fixture/2`'s host credential expects in the environment."
  def token, do: @token

  @doc """
  Writes a complete two-tool deployment into `dir` and returns its gateway
  document path and decoded configuration. `effect` is the workflow's declared
  effect; `:write` additionally requires the caller to grant `allow_write` and
  configure a private audit directory.

  `opts[:body]` replaces the workflow body, whose default returns its input
  unchanged. A concurrency measurement needs a run that lasts long enough to
  observe — see `PtcGateway.TestSupport.GatewayLoad`'s note on what a
  client-side interval can prove — and that is the only reason to override it.

  `opts[:schema]` replaces the schema shared by the input and result contracts.
  The default admits `%{}` and nothing else: contract compilation injects
  `additionalProperties: false`, so a bare `{"type": "object"}` accepts no keys
  at all. A case that sends or returns a payload declares those properties here,
  or its call comes back as a contract error inside an HTTP 200.
  """
  def fixture(dir, effect \\ :read, opts \\ []) do
    File.mkdir_p!(dir)
    body = Keyword.get(opts, :body, "(return input)")

    File.write!(
      Path.join(dir, "workflow.clj"),
      "(ns app) (defn run {:effect :#{effect}} [input] #{body})"
    )

    schema = Keyword.get(opts, :schema, %{"type" => "object"})
    File.write!(Path.join(dir, "schema.json"), Jason.encode!(schema))

    manifest = %{
      "version" => 1,
      "workflow" => %{
        "components" => [%{"id" => "app", "path" => "workflow.clj"}],
        "entry" => "app/run"
      },
      "input" => %{"path" => "missing.json"},
      "contracts" => %{
        "input_schema" => %{"path" => "schema.json"},
        "result_schema" => %{"path" => "schema.json"}
      }
    }

    manifest_path = Path.join(dir, "app.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    {:ok, template} = ServingTemplate.from_directory(manifest_path, Limits.installed_defaults())

    File.write!(
      Path.join(dir, "host.json"),
      Jason.encode!(%{
        "credentials" => %{"gateway" => %{"env" => "GATEWAY_TEST_TOKEN"}},
        "install" => %{}
      })
    )

    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    tool = %{
      "name" => "a",
      "title" => "A",
      "description" => "A tool",
      "application" => %{"manifest" => "app.json"},
      "expected_application_content_digest" =>
        ServingTemplate.application_content_digest(template),
      "installation_config_pins" => %{},
      "provider_snapshot_pins" => %{}
    }

    config = %{
      "version" => 1,
      "listen" => %{"address" => "127.0.0.1", "port" => port, "path" => "/mcp"},
      "authentication" => %{"bearer" => %{"binding" => "gateway"}},
      "host" => %{"path" => "host.json"},
      "admission" => %{
        "max_inflight_requests" => 16,
        "max_concurrent_runs" => 4,
        "max_active_provider_calls" => 4,
        "max_waiting_provider_calls" => 0
      },
      "tools" => [Map.put(tool, "name", "z"), tool]
    }

    path = Path.join(dir, "gateway.json")
    File.write!(path, Jason.encode!(config))
    {path, config}
  end

  @doc "One HTTP request against the fixture's listener. `opts` are `Req.request!/1` options."
  def response(config, path, opts \\ []) do
    Req.request!(
      [url: "http://127.0.0.1:#{config["listen"]["port"]}#{path}", retry: false] ++ opts
    )
  end

  @doc """
  One well-formed MCP request. `:params` merges into the required `_meta`;
  `:full_params` and `:raw_body` replace them outright for malformed cases.
  """
  def mcp(config, method, id, opts \\ []) do
    protocol = Keyword.get(opts, :protocol, "2026-07-28")

    params =
      Keyword.get_lazy(opts, :full_params, fn ->
        Map.merge(
          %{
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => protocol,
              "io.modelcontextprotocol/clientCapabilities" => %{}
            }
          },
          Keyword.get(opts, :params, %{})
        )
      end)

    body =
      Keyword.get_lazy(opts, :raw_body, fn ->
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
      end)

    headers =
      [
        {"authorization", "Bearer #{Keyword.get(opts, :token, @token)}"},
        {"content-type", Keyword.get(opts, :content_type, "application/json")},
        {"accept", Keyword.get(opts, :accept, "application/json, text/event-stream")},
        {"mcp-protocol-version", protocol}
      ] ++
        if Keyword.get(opts, :method_header, true), do: [{"mcp-method", method}], else: []

    response(config, "/mcp",
      method: :post,
      headers: headers ++ Keyword.get(opts, :headers, []),
      body: body
    )
  end

  @doc "Stops a gateway owner that may already have exited."
  def stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
