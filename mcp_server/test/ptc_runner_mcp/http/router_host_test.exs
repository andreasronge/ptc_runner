defmodule PtcRunnerMcp.Http.RouterHostTest do
  use PtcRunnerMcp.Http.RouterCase

  test "GET /mcp with bad Host returns 403 before 405" do
    conn =
      conn(:get, "/mcp")
      |> auth()
      |> with_host("attacker.example")
      |> call()

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  test "loopback bind rejects hostile Host before reading MCP POST body" do
    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
      )
      |> auth()
      |> with_host("attacker.example")
      |> call()

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  test "loopback bind rejects hostile Host on DELETE" do
    conn =
      conn(:delete, "/mcp")
      |> auth()
      |> with_host("attacker.example")
      |> call()

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end
end
