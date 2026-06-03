defmodule PtcRunnerMcp.Http.RouterAuthTest do
  use PtcRunnerMcp.Http.RouterCase

  alias PtcRunnerMcp.Http.AuthRateLimiter
  alias PtcRunnerMcp.Http.Router

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

  describe "failed auth rate limiting" do
    setup %{cfg: cfg} do
      cfg = %{
        cfg
        | auth_rate_limit: true,
          auth_rate_limit_window_ms: 60_000,
          auth_rate_limit_max_failures: 3,
          auth_rate_limit_block_ms: 60_000
      }

      Application.put_env(:ptc_runner_mcp, :http_config, cfg)
      start_supervised!({AuthRateLimiter, [config: cfg]})
      {:ok, cfg: cfg}
    end

    test "repeated invalid bearer attempts from the same source return 429 with Retry-After" do
      for _ <- 1..3, do: assert(bad_auth_post().status == 401)

      conn = bad_auth_post()
      assert conn.status == 429
      [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
      # A blocked source must not be told whether its token was invalid.
      assert get_resp_header(conn, "www-authenticate") == []
    end

    test "a different source is unaffected while the first is blocked" do
      for _ <- 1..4, do: bad_auth_post({1, 2, 3, 4})
      assert bad_auth_post({1, 2, 3, 4}).status == 429

      # A distinct source still gets the normal 401 challenge.
      conn = bad_auth_post({5, 6, 7, 8})
      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")]
    end

    test "valid auth below threshold is not blocked" do
      assert bad_auth_post().status == 401
      assert valid_initialize().status == 200
    end

    test "successful auth resets prior failed state" do
      for _ <- 1..2, do: assert(bad_auth_post().status == 401)
      assert valid_initialize().status == 200
      # Counter was reset: two more failures stay below the threshold.
      for _ <- 1..2, do: assert(bad_auth_post().status == 401)
    end

    test "missing Authorization failures are counted" do
      for _ <- 1..3 do
        conn =
          conn(:post, "/mcp", "{}")
          |> put_req_header("content-type", "application/json")
          |> call()

        assert conn.status == 401
      end

      conn =
        conn(:post, "/mcp", "{}")
        |> put_req_header("content-type", "application/json")
        |> call()

      assert conn.status == 429
    end

    test "Host rejections do not increment the failure counter" do
      for _ <- 1..5 do
        conn =
          conn(:post, "/mcp", "{}")
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer nope")
          |> with_host("attacker.example")
          |> Router.call([])

        assert conn.status == 403
      end

      # No bearer failures were recorded, so a valid auth still succeeds.
      assert valid_initialize().status == 200
    end

    test "Origin rejections do not increment the failure counter" do
      for _ <- 1..5 do
        conn =
          conn(:post, "/mcp", "{}")
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer nope")
          |> with_host("127.0.0.1")
          |> put_req_header("origin", "http://attacker.example")
          |> Router.call([])

        assert conn.status == 403
      end

      assert valid_initialize().status == 200
    end
  end

  test "rate limiting disabled: no blocking even after many failures", %{cfg: cfg} do
    cfg = %{cfg | auth_rate_limit: false, auth_rate_limit_max_failures: 3}
    Application.put_env(:ptc_runner_mcp, :http_config, cfg)
    start_supervised!({AuthRateLimiter, [config: cfg]})

    for _ <- 1..10, do: assert(bad_auth_post().status == 401)
  end

  defp bad_auth_post(remote_ip \\ {127, 0, 0, 1}) do
    conn(:post, "/mcp", "{}")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer nope")
    |> with_remote_ip(remote_ip)
    |> call()
  end

  defp valid_initialize do
    init = %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}

    conn(:post, "/mcp", Jason.encode!(init))
    |> auth()
    |> call()
  end

  defp with_remote_ip(conn, ip), do: %{conn | remote_ip: ip}
end
