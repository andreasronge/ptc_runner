defmodule PtcGateway.HTTP.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias PtcGateway.Admission
  alias PtcGateway.HTTP.Auth
  alias PtcGateway.HTTP.Router
  alias PtcGateway.Protocol

  @token "gateway-token-fixture"
  @authority {"127.0.0.1", 4180}
  @origin "http://127.0.0.1:4180"
  @auth_source Path.expand("../../../lib/ptc_gateway/http/auth.ex", __DIR__)

  @input_schema %{
    "type" => "object",
    "properties" => %{"n" => %{"type" => "integer"}},
    "required" => ["n"],
    "additionalProperties" => false
  }
  @output_schema %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "integer"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }

  setup do
    {:ok, admission} = start_supervised({Admission, ceiling: 2})
    {:ok, admission: admission}
  end

  test "bearer comparison uses the constant-time primitive" do
    source = File.read!(@auth_source)
    assert source =~ "Plug.Crypto.secure_compare"
    refute Auth.matches?("gateway-token-fixture", "gateway-token-fixturX")
    assert Auth.matches?(@token, @token)
  end

  test "health is unauthenticated", %{admission: admission} do
    conn = call(:get, "/health", admission)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
  end

  test "ready and mcp require bearer authentication", %{admission: admission} do
    ready = call(:get, "/ready", admission, authorize?: false)
    assert ready.status == 401

    mcp = call(:post, "/mcp", admission, authorize?: false, body: request(1, "tools/list", %{}))
    assert mcp.status == 401
  end

  test "lists two tools over JSON POST", %{admission: admission} do
    conn = call(:post, "/mcp", admission, body: request(2, "tools/list", %{}))
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    names = body["result"]["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ["double", "echo"]
  end

  test "calls a tool through the request owner", %{admission: admission} do
    conn =
      call(:post, "/mcp", admission,
        body: request(3, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 7}})
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["result"]["structuredContent"] == %{"answer" => 7}
    assert body["result"]["isError"] == false
  end

  test "a present Origin must match the allowlist exactly", %{admission: admission} do
    rejected =
      call(:post, "/mcp", admission,
        body: request(1, "tools/list", %{}),
        origin: "http://evil.example"
      )

    assert rejected.status == 403

    allowed =
      call(:post, "/mcp", admission,
        body: request(1, "tools/list", %{}),
        origin: @origin
      )

    assert allowed.status == 200
  end

  test "Host must match the configured authority and ignores forwarded headers", %{
    admission: admission
  } do
    conn =
      conn(:post, "/mcp", request(1, "tools/list", %{}))
      |> Map.put(:host, "127.0.0.1")
      |> Map.put(:port, 4180)
      |> put_host_header("evil.example")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{@token}")
      |> Plug.Conn.put_req_header("x-forwarded-host", "127.0.0.1:4180")
      |> Plug.Conn.put_req_header("forwarded", "host=127.0.0.1:4180")
      |> Router.call(router_opts(admission))

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "host rejected"}
  end

  test "bearer scheme matching is case-insensitive", %{admission: admission} do
    conn =
      conn(:post, "/mcp", request(1, "tools/list", %{}))
      |> put_host_header(host_header())
      |> Plug.Conn.put_req_header("authorization", "bearer #{@token}")
      |> Router.call(router_opts(admission))

    assert conn.status == 200
  end

  test "the token is not assigned onto the connection", %{admission: admission} do
    conn = call(:get, "/health", admission)
    refute Map.has_key?(conn.assigns.gateway, :token)
    refute Map.has_key?(conn.private, :ptc_gateway_token)
  end

  test "bodies larger than the protocol frame cap are parse errors", %{admission: admission} do
    body = :binary.copy("x", Protocol.max_frame_bytes() + 1)

    conn =
      conn(:post, "/mcp", body)
      |> put_host_header(host_header())
      |> Plug.Conn.put_req_header("authorization", "Bearer #{@token}")
      |> Router.call(router_opts(admission))

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["error"]["code"] == -32_700
  end

  test "HTTP cancellation is rejected", %{admission: admission} do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 1}
      })

    conn = call(:post, "/mcp", admission, body: body)
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "cancellation unsupported over HTTP"}
  end

  defp call(method, path, admission, opts \\ []) do
    body = Keyword.get(opts, :body)
    authorize? = Keyword.get(opts, :authorize?, true)

    conn(method, path, body)
    |> put_host_header(host_header())
    |> maybe_authorize(authorize?)
    |> maybe_origin(Keyword.get(opts, :origin))
    |> Router.call(router_opts(admission))
  end

  defp host_header do
    {host, port} = @authority
    "#{host}:#{port}"
  end

  defp put_host_header(conn, header) do
    %{conn | req_headers: List.keystore(conn.req_headers, "host", 0, {"host", header})}
  end

  defp maybe_authorize(conn, true),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{@token}")

  defp maybe_authorize(conn, false), do: conn

  defp maybe_origin(conn, nil), do: conn
  defp maybe_origin(conn, origin), do: Plug.Conn.put_req_header(conn, "origin", origin)

  defp router_opts(admission) do
    tools = tools()

    [
      token: @token,
      authority: @authority,
      origin_allowlist: [@origin],
      admission: admission,
      catalog: tools,
      tools: Map.new(tools, &{&1.name, &1})
    ]
  end

  defp tools do
    [
      %{
        name: "echo",
        description: "Echo n",
        input_schema: @input_schema,
        output_schema: @output_schema,
        meta: %{"ptc/application_content_digest" => "a"},
        call: fn arguments -> {:ok, %{"answer" => arguments["n"]}} end
      },
      %{
        name: "double",
        description: "Double n",
        input_schema: @input_schema,
        output_schema: @output_schema,
        meta: %{"ptc/application_content_digest" => "b"},
        call: fn arguments -> {:ok, %{"answer" => arguments["n"] * 2}} end
      }
    ]
  end

  defp request(id, method, params) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end
end
