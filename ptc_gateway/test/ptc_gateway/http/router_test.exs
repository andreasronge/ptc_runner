defmodule PtcGateway.HTTP.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias PtcGateway.Admission
  alias PtcGateway.HTTP.Auth
  alias PtcGateway.HTTP.Router
  alias PtcGateway.HTTP.Secret
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
    {:ok, secret} = Secret.start_link([])
    :ok = Secret.install(secret, @token)
    on_exit(fn -> if Process.alive?(secret), do: GenServer.stop(secret) end)
    {:ok, admission: admission, secret: secret}
  end

  test "bearer comparison uses the constant-time primitive" do
    source = File.read!(@auth_source)
    assert source =~ "Plug.Crypto.secure_compare"
    refute Auth.matches?("gateway-token-fixture", "gateway-token-fixturX")
    assert Auth.matches?(@token, @token)
  end

  test "health is unauthenticated", ctx do
    conn = call(:get, "/health", ctx)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
  end

  test "ready and mcp require bearer authentication", ctx do
    ready = call(:get, "/ready", ctx, authorize?: false)
    assert ready.status == 401

    mcp = call(:post, "/mcp", ctx, authorize?: false, body: request(1, "tools/list", %{}))
    assert mcp.status == 401
  end

  test "ready is unready when the catalog is empty", ctx do
    conn =
      conn(:get, "/ready")
      |> put_host_header(host_header())
      |> maybe_authorize(true)
      |> Router.call(
        secret: ctx.secret,
        authority: @authority,
        origin_allowlist: [@origin],
        admission: ctx.admission,
        catalog: [],
        tools: %{}
      )

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body) == %{"status" => "unready"}
  end

  test "lists two tools over JSON POST", ctx do
    conn = call(:post, "/mcp", ctx, body: request(2, "tools/list", %{}))
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    names = body["result"]["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()
    assert names == ["double", "echo"]
  end

  test "calls a tool through the request owner", ctx do
    conn =
      call(:post, "/mcp", ctx,
        body: request(3, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 7}})
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["result"]["structuredContent"] == %{"answer" => 7}
    assert body["result"]["isError"] == false
  end

  test "tools/call with event-stream Accept is an SSE response", ctx do
    conn =
      call(:post, "/mcp", ctx,
        body: request(3, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 7}}),
        accept: "text/event-stream"
      )

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/event-stream"]
    assert conn.resp_body =~ ": \n\n"
    body = sse_json(conn.resp_body)
    assert body["result"]["structuredContent"] == %{"answer" => 7}
  end

  test "SSE tools/call errors stay on the event-stream transport", ctx do
    unknown =
      call(:post, "/mcp", ctx,
        body: request(4, "tools/call", %{"name" => "missing", "arguments" => %{}}),
        accept: "text/event-stream"
      )

    assert Plug.Conn.get_resp_header(unknown, "content-type") == ["text/event-stream"]
    assert sse_json(unknown.resp_body)["error"]["code"] == -32_602

    invalid =
      call(:post, "/mcp", ctx,
        body: request(5, "tools/call", %{"name" => 1, "arguments" => %{}}),
        accept: "text/event-stream"
      )

    assert Plug.Conn.get_resp_header(invalid, "content-type") == ["text/event-stream"]
    assert sse_json(invalid.resp_body)["error"]["code"] == -32_602

    holders =
      for _index <- 1..2 do
        spawn(fn -> receive do: (:never -> :never) end)
      end

    on_exit(fn -> Enum.each(holders, &Process.exit(&1, :kill)) end)

    Enum.each(holders, fn holder ->
      assert :ok = Admission.checkout(ctx.admission, holder)
    end)

    saturated =
      call(:post, "/mcp", ctx,
        body: request(6, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 1}}),
        accept: "text/event-stream"
      )

    assert Plug.Conn.get_resp_header(saturated, "content-type") == ["text/event-stream"]
    assert sse_json(saturated.resp_body)["error"]["code"] == -32_000
  end

  test "SSE Accept requires the event-stream type and a positive q", ctx do
    prefix =
      call(:post, "/mcp", ctx,
        body: request(3, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 1}}),
        accept: "text/event-streaming"
      )

    assert hd(Plug.Conn.get_resp_header(prefix, "content-type")) =~ "json"

    rejected =
      call(:post, "/mcp", ctx,
        body: request(3, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 1}}),
        accept: "text/event-stream;q=0"
      )

    assert hd(Plug.Conn.get_resp_header(rejected, "content-type")) =~ "json"

    parameterized =
      call(:post, "/mcp", ctx,
        body: request(3, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 1}}),
        accept: "text/event-stream; charset=utf-8"
      )

    assert Plug.Conn.get_resp_header(parameterized, "content-type") == ["text/event-stream"]

    quoted_comma =
      call(:post, "/mcp", ctx,
        body: request(3, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 1}}),
        accept: ~s(text/event-stream; profile="a,b"; q=0)
      )

    assert hd(Plug.Conn.get_resp_header(quoted_comma, "content-type")) =~ "json"

    quoted_semicolon =
      call(:post, "/mcp", ctx,
        body: request(3, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 1}}),
        accept: ~s(text/event-stream; profile="a;q=0")
      )

    assert Plug.Conn.get_resp_header(quoted_semicolon, "content-type") == ["text/event-stream"]

    unterminated =
      call(:post, "/mcp", ctx,
        body: request(3, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 1}}),
        accept: ~s(text/event-stream; profile="unterminated)
      )

    assert hd(Plug.Conn.get_resp_header(unterminated, "content-type")) =~ "json"

    dangling_escape =
      call(:post, "/mcp", ctx,
        body: request(3, "tools/call", %{"name" => "echo", "arguments" => %{"n" => 1}}),
        accept: "text/event-stream; profile=\"ok\\"
      )

    assert hd(Plug.Conn.get_resp_header(dangling_escape, "content-type")) =~ "json"
  end

  test "a present Origin must match the allowlist exactly", ctx do
    rejected =
      call(:post, "/mcp", ctx,
        body: request(1, "tools/list", %{}),
        origin: "http://evil.example"
      )

    assert rejected.status == 403

    allowed =
      call(:post, "/mcp", ctx,
        body: request(1, "tools/list", %{}),
        origin: @origin
      )

    assert allowed.status == 200
  end

  test "Host must match the configured authority and ignores forwarded headers", ctx do
    conn =
      conn(:post, "/mcp", request(1, "tools/list", %{}))
      |> Map.put(:host, "127.0.0.1")
      |> Map.put(:port, 4180)
      |> put_host_header("evil.example")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{@token}")
      |> Plug.Conn.put_req_header("x-forwarded-host", "127.0.0.1:4180")
      |> Plug.Conn.put_req_header("forwarded", "host=127.0.0.1:4180")
      |> Router.call(router_opts(ctx))

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "host rejected"}
  end

  test "bearer scheme matching is case-insensitive", ctx do
    conn =
      conn(:post, "/mcp", request(1, "tools/list", %{}))
      |> put_host_header(host_header())
      |> Plug.Conn.put_req_header("authorization", "bearer #{@token}")
      |> Router.call(router_opts(ctx))

    assert conn.status == 200
  end

  test "the token is not assigned onto the connection", ctx do
    conn = call(:get, "/health", ctx)
    refute Map.has_key?(conn.assigns.gateway, :token)
    refute Map.has_key?(conn.private, :ptc_gateway_token)
    refute inspect(conn.assigns.gateway) =~ @token
    refute Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@token}"]
  end

  test "bodies larger than the protocol frame cap are parse errors", ctx do
    body = :binary.copy("x", Protocol.max_frame_bytes() + 1)

    conn =
      conn(:post, "/mcp", body)
      |> put_host_header(host_header())
      |> Plug.Conn.put_req_header("authorization", "Bearer #{@token}")
      |> Router.call(router_opts(ctx))

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["error"]["code"] == -32_700
  end

  test "HTTP cancellation is rejected", ctx do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 1}
      })

    conn = call(:post, "/mcp", ctx, body: body)
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "cancellation unsupported over HTTP"}
  end

  defp call(method, path, ctx, opts \\ []) do
    body = Keyword.get(opts, :body)
    authorize? = Keyword.get(opts, :authorize?, true)

    conn(method, path, body)
    |> put_host_header(host_header())
    |> maybe_authorize(authorize?)
    |> maybe_origin(Keyword.get(opts, :origin))
    |> maybe_accept(Keyword.get(opts, :accept))
    |> Router.call(router_opts(ctx))
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

  defp maybe_accept(conn, nil), do: conn
  defp maybe_accept(conn, accept), do: Plug.Conn.put_req_header(conn, "accept", accept)

  defp sse_json(body) do
    body
    |> String.split("\n\n")
    |> Enum.find_value(fn event ->
      data =
        event
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map_join("\n", &String.trim_leading(&1, "data:"))
        |> String.trim()

      if data != "", do: Jason.decode!(data)
    end)
  end

  defp router_opts(ctx) do
    tools = tools()

    [
      secret: ctx.secret,
      authority: @authority,
      origin_allowlist: [@origin],
      admission: ctx.admission,
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
