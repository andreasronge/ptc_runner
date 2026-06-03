defmodule PtcRunnerMcp.Http.RouterOriginTest do
  use PtcRunnerMcp.Http.RouterCase

  test "GET /mcp with invalid Origin returns 403 before 405" do
    conn =
      conn(:get, "/mcp")
      |> auth()
      |> with_host("127.0.0.1")
      |> put_req_header("origin", "http://attacker.example")
      |> call()

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  test "missing Origin is allowed when Host is loopback" do
    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
      )
      |> auth()
      |> with_host("127.0.0.1")
      |> call()

    assert conn.status == 200
    assert get_resp_header(conn, "mcp-session-id") != []
  end

  test "invalid browser Origin is rejected even with loopback Host" do
    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
      )
      |> auth()
      |> with_host("127.0.0.1")
      |> put_req_header("origin", "http://attacker.example")
      |> call()

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end
end
