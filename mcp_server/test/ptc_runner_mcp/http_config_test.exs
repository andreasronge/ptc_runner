defmodule PtcRunnerMcp.HttpConfigTest do
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.Http.Config

  setup do
    original_http_env =
      System.get_env()
      |> Enum.filter(fn {key, _value} -> String.starts_with?(key, "PTC_RUNNER_MCP_HTTP_") end)

    Enum.each(original_http_env, fn {key, _value} -> System.delete_env(key) end)

    on_exit(fn ->
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "PTC_RUNNER_MCP_HTTP_"))
      |> Enum.each(&System.delete_env/1)

      Enum.each(original_http_env, fn {key, value} -> System.put_env(key, value) end)
    end)

    :ok
  end

  test "rejects short auth tokens" do
    assert {:error, message} =
             Config.resolve(%{
               http: true,
               http_host: "0.0.0.0",
               http_auth_token: "short"
             })

    assert message =~ "at least 32"
  end

  test "requires auth for non-loopback binds" do
    assert {:error, message} = Config.resolve(%{http: true, http_host: "0.0.0.0"})
    assert message =~ "required"
  end

  test "rejects disable-auth on non-loopback even with allow-unsafe-network" do
    assert {:error, message} =
             Config.resolve(%{
               http: true,
               http_host: "0.0.0.0",
               http_disable_auth: true,
               http_allow_unsafe_network: true
             })

    assert message =~ "cannot be combined"
  end

  test "rejects disable-auth with allow-unsafe-network on loopback" do
    assert {:error, message} =
             Config.resolve(%{
               http: true,
               http_host: "127.0.0.1",
               http_disable_auth: true,
               http_allow_unsafe_network: true
             })

    assert message =~ "cannot be combined"
  end

  test "rejects disable-auth on non-loopback without allow-unsafe-network" do
    assert {:error, message} =
             Config.resolve(%{
               http: true,
               http_host: "0.0.0.0",
               http_disable_auth: true
             })

    assert message =~ "only permitted on loopback"
  end

  test "allows disable-auth on loopback without allow-unsafe-network" do
    assert {:ok, cfg} =
             Config.resolve(%{http: true, http_host: "127.0.0.1", http_disable_auth: true})

    assert cfg.auth_disabled
  end

  test "rejects endpoint path collisions" do
    assert {:error, "HTTP paths must be distinct"} =
             Config.resolve(%{http: true, http_path: "/health"})
  end

  test "loopback detection covers 127/8 and ::1" do
    assert Config.loopback_host?("127.9.8.7")
    assert Config.loopback_host?("::1")
    refute Config.loopback_host?("0.0.0.0")
  end

  test "rejects non-IP bind hostnames except localhost" do
    assert {:ok, cfg} = Config.resolve(%{http: true, http_host: "localhost"})
    assert cfg.host == "localhost"

    assert {:error, message} =
             Config.resolve(%{
               http: true,
               http_host: "example.internal",
               http_auth_token: String.duplicate("a", 32)
             })

    assert message =~ "IP address or localhost"
  end

  test "parse_args preserves repeated allowed-origin flags" do
    args =
      PtcRunnerMcp.Application.parse_args([
        "--http-allowed-origin",
        "http://a.test",
        "--http-allowed-origin",
        "http://b.test"
      ])

    assert args.http_allowed_origin == ["http://a.test", "http://b.test"]
  end

  test "auth rate limit defaults are enabled with sane thresholds" do
    assert {:ok, cfg} = Config.resolve(%{http: true, http_auth_token: String.duplicate("a", 32)})
    assert cfg.auth_rate_limit == true
    assert cfg.auth_rate_limit_window_ms == 60_000
    assert cfg.auth_rate_limit_max_failures == 5
    assert cfg.auth_rate_limit_block_ms == 60_000
  end

  test "auth rate limit honors CLI overrides" do
    assert {:ok, cfg} =
             Config.resolve(%{
               http: true,
               http_auth_token: String.duplicate("a", 32),
               http_auth_rate_limit: false,
               http_auth_rate_limit_window_ms: 1_000,
               http_auth_rate_limit_max_failures: 2,
               http_auth_rate_limit_block_ms: 5_000
             })

    assert cfg.auth_rate_limit == false
    assert cfg.auth_rate_limit_window_ms == 1_000
    assert cfg.auth_rate_limit_max_failures == 2
    assert cfg.auth_rate_limit_block_ms == 5_000
  end

  test "rejects non-positive rate limit integer overrides" do
    for {key, value} <- [
          {:http_auth_rate_limit_max_failures, 0},
          {:http_auth_rate_limit_max_failures, -1},
          {:http_auth_rate_limit_window_ms, 0},
          {:http_auth_rate_limit_block_ms, -5}
        ] do
      args =
        Map.put(%{http: true, http_auth_token: String.duplicate("a", 32)}, key, value)

      assert {:error, message} = Config.resolve(args)
      assert message =~ "must be a positive integer"
    end
  end

  test "rejects non-numeric integer config values" do
    assert {:error, message} =
             Config.resolve(%{
               http: true,
               http_auth_token: String.duplicate("a", 32),
               http_port: "abc"
             })

    assert message =~ "--http-port"
    assert message =~ "must be a positive integer"
  end

  test "rejects invalid integer config supplied via env var" do
    System.put_env("PTC_RUNNER_MCP_HTTP_PORT", "0")

    assert {:error, message} =
             Config.resolve(%{http: true, http_auth_token: String.duplicate("a", 32)})

    assert message =~ "--http-port"
    assert message =~ "must be a positive integer"
  end

  test "omitted integer fields resolve to documented defaults" do
    assert {:ok, cfg} = Config.resolve(%{http: true, http_auth_token: String.duplicate("a", 32)})

    assert cfg.port == 7332
    assert cfg.auth_rate_limit_max_failures == 5
    assert cfg.auth_rate_limit_window_ms == 60_000
    assert cfg.auth_rate_limit_block_ms == 60_000
  end

  test "invalid integer config is silently defaulted when HTTP is disabled" do
    assert {:ok, cfg} =
             Config.resolve(%{
               http: false,
               http_auth_rate_limit_max_failures: 0,
               http_port: "abc"
             })

    assert cfg.enabled == false
    assert cfg.auth_rate_limit_max_failures == 5
    assert cfg.port == 7332
  end

  test "default body limit follows the applied max frame limit" do
    on_exit(fn -> PtcRunnerMcp.Limits.set(PtcRunnerMcp.Limits.defaults()) end)

    args = %{http: true, max_frame_bytes: 12_345}

    :ok = PtcRunnerMcp.Application.apply_limits(args)
    assert {:ok, cfg} = Config.resolve(args)
    assert cfg.max_body_bytes == 12_345
  end
end
