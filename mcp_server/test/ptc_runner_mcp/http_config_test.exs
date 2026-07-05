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

  test "rejects short admin tokens" do
    assert {:error, message} =
             Config.resolve(%{
               http: true,
               http_admin_token: "short"
             })

    assert message =~ "HTTP admin token"
    assert message =~ "at least 32"
  end

  test "accepts admin token from args and env" do
    token = String.duplicate("m", 32)

    assert {:ok, cfg} =
             Config.resolve(%{
               http: true,
               http_auth_token: String.duplicate("a", 32),
               http_admin_token: token
             })

    assert cfg.admin_token == token

    System.put_env("PTC_RUNNER_MCP_HTTP_ADMIN_TOKEN", String.duplicate("n", 32))
    assert {:ok, cfg} = Config.resolve(%{http: true, http_auth_token: String.duplicate("a", 32)})
    assert cfg.admin_token == String.duplicate("n", 32)
  end

  test "rejects reusing the MCP bearer token as the admin token" do
    token = String.duplicate("s", 32)

    assert {:error, message} =
             Config.resolve(%{
               http: true,
               http_auth_token: token,
               http_admin_token: token
             })

    assert message =~ "admin token"
    assert message =~ "different"
  end

  test "loads role-token file and rejects legacy MCP token coexistence" do
    token = String.duplicate("r", 32)

    path =
      write_role_tokens!(%{
        "tokens" => [%{"id" => "analyst-a", "token_literal" => token, "roles" => ["analyst"]}]
      })

    assert {:ok, cfg} = Config.resolve(%{http: true, http_role_tokens: path})
    assert cfg.auth_token == nil
    assert map_size(cfg.role_tokens) == 1
    assert cfg.role_token_redaction_secrets == [token]

    assert {:error, message} =
             Config.resolve(%{
               http: true,
               http_auth_token: String.duplicate("a", 32),
               http_role_tokens: path
             })

    assert message =~ "cannot be combined"
  end

  test "role-token file satisfies non-loopback auth requirement" do
    path =
      write_role_tokens!(%{
        "tokens" => [
          %{
            "id" => "analyst-a",
            "token_literal" => String.duplicate("r", 32),
            "roles" => ["analyst"]
          }
        ]
      })

    assert {:ok, cfg} =
             Config.resolve(%{http: true, http_host: "0.0.0.0", http_role_tokens: path})

    assert cfg.host == "0.0.0.0"
  end

  test "rejects malformed role-token files" do
    assert {:error, message} =
             Config.resolve(%{
               http: true,
               http_role_tokens: write_role_tokens!(%{"tokenz" => []})
             })

    assert message =~ "tokens array"

    assert {:error, message} =
             Config.resolve(%{
               http: true,
               http_role_tokens:
                 write_role_tokens!(%{
                   "tokens" => [
                     %{
                       "id" => "bad role",
                       "token_literal" => String.duplicate("r", 32),
                       "roles" => ["analyst"]
                     }
                   ]
                 })
             })

    assert message =~ "tokens[0].id"

    assert {:error, message} =
             Config.resolve(%{
               http: true,
               http_admin_token: String.duplicate("r", 32),
               http_role_tokens:
                 write_role_tokens!(%{
                   "tokens" => [
                     %{
                       "id" => "analyst",
                       "token_literal" => String.duplicate("r", 32),
                       "roles" => ["analyst"]
                     }
                   ]
                 })
             })

    assert message =~ "different from HTTP admin token"

    assert {:error, message} =
             Config.resolve(%{
               http: true,
               http_role_tokens:
                 write_role_tokens!(%{
                   "tokens" => [
                     %{
                       "id" => "duplicate",
                       "token_literal" => String.duplicate("r", 32),
                       "roles" => ["analyst"]
                     },
                     %{
                       "id" => "duplicate",
                       "token_literal" => String.duplicate("s", 32),
                       "roles" => ["editor"]
                     }
                   ]
                 })
             })

    assert message =~ "duplicates"
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

  test "rejects MCP path collision with admin endpoints" do
    assert {:error, "HTTP paths must be distinct"} =
             Config.resolve(%{http: true, http_path: "/admin/prelude-store/snapshot"})
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
    assert message =~ "PTC_RUNNER_MCP_HTTP_PORT"
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

  defp write_role_tokens!(json) do
    dir =
      Path.join(System.tmp_dir!(), "ptc_mcp_role_tokens_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, "role_tokens.json")
    File.write!(path, Jason.encode!(json))
    path
  end
end
