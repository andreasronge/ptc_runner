defmodule PtcRunnerMcp.Http.RouterAuthTest do
  use PtcRunnerMcp.Http.RouterCase

  test "unauthenticated GET /mcp returns 401 bearer challenge" do
    conn = call(conn(:get, "/mcp"))
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
  end

  test "health and ready are unauthenticated" do
    assert call(conn(:get, "/health")).status == 200
    assert call(conn(:get, "/ready")).status == 200
  end

  test "missing and bad auth return bearer challenges" do
    conn =
      conn(:post, "/mcp", "{}") |> put_req_header("content-type", "application/json") |> call()

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]

    conn =
      conn(:post, "/mcp", "{}")
      |> put_req_header("authorization", "Bearer nope")
      |> call()

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")]
  end
end
