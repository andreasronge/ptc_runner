defmodule PtcRunnerMcp.Http.Config do
  @moduledoc false

  alias PtcRunnerMcp.{Limits, Log}

  @default_host "127.0.0.1"
  @default_port 7332
  @default_path "/mcp"
  @default_request_timeout_ms 15_000
  @default_shutdown_grace_ms 10_000
  @default_session_ttl_ms 3_600_000
  @default_session_idle_timeout_ms 900_000
  @default_max_sessions 256
  @default_max_sessions_per_owner 32
  @default_max_in_flight_per_session 4
  @token_min_bytes 32

  @type t :: %{
          enabled: boolean(),
          host: String.t(),
          port: pos_integer(),
          path: String.t(),
          auth_token: String.t() | nil,
          auth_disabled: boolean(),
          allowed_origins: [String.t()],
          request_timeout_ms: pos_integer(),
          shutdown_grace_ms: pos_integer(),
          max_body_bytes: pos_integer(),
          session_ttl_ms: pos_integer(),
          session_idle_timeout_ms: pos_integer(),
          max_sessions: pos_integer(),
          max_sessions_per_owner: pos_integer(),
          max_in_flight_per_session: pos_integer(),
          allow_unsafe_network: boolean(),
          metrics?: boolean(),
          metrics_path: String.t(),
          instance_label: String.t()
        }

  @doc false
  @spec resolve(map()) :: {:ok, t()} | {:error, String.t()}
  def resolve(args) when is_map(args) do
    cfg = %{
      enabled: read_bool(args, :http, "PTC_RUNNER_MCP_HTTP", false),
      host: read_string(args, :http_host, "PTC_RUNNER_MCP_HTTP_HOST", @default_host),
      port: read_int(args, :http_port, "PTC_RUNNER_MCP_HTTP_PORT", @default_port),
      path:
        normalize_path(read_string(args, :http_path, "PTC_RUNNER_MCP_HTTP_PATH", @default_path)),
      auth_token: read_optional_string(args, :http_auth_token, "PTC_RUNNER_MCP_HTTP_AUTH_TOKEN"),
      auth_disabled:
        read_bool(args, :http_disable_auth, "PTC_RUNNER_MCP_HTTP_DISABLE_AUTH", false),
      allowed_origins:
        read_list(args, :http_allowed_origin, "PTC_RUNNER_MCP_HTTP_ALLOWED_ORIGIN"),
      request_timeout_ms:
        read_int(
          args,
          :http_request_timeout_ms,
          "PTC_RUNNER_MCP_HTTP_REQUEST_TIMEOUT_MS",
          @default_request_timeout_ms
        ),
      shutdown_grace_ms:
        read_int(
          args,
          :http_shutdown_grace_ms,
          "PTC_RUNNER_MCP_HTTP_SHUTDOWN_GRACE_MS",
          @default_shutdown_grace_ms
        ),
      max_body_bytes:
        read_int(
          args,
          :http_max_body_bytes,
          "PTC_RUNNER_MCP_HTTP_MAX_BODY_BYTES",
          Limits.max_frame_bytes()
        ),
      session_ttl_ms:
        read_int(
          args,
          :http_session_ttl_ms,
          "PTC_RUNNER_MCP_HTTP_SESSION_TTL_MS",
          @default_session_ttl_ms
        ),
      session_idle_timeout_ms:
        read_int(
          args,
          :http_session_idle_timeout_ms,
          "PTC_RUNNER_MCP_HTTP_SESSION_IDLE_TIMEOUT_MS",
          @default_session_idle_timeout_ms
        ),
      max_sessions:
        read_int(
          args,
          :http_max_sessions,
          "PTC_RUNNER_MCP_HTTP_MAX_SESSIONS",
          @default_max_sessions
        ),
      max_sessions_per_owner:
        read_int(
          args,
          :http_max_sessions_per_owner,
          "PTC_RUNNER_MCP_HTTP_MAX_SESSIONS_PER_OWNER",
          @default_max_sessions_per_owner
        ),
      max_in_flight_per_session:
        read_int(
          args,
          :http_max_in_flight_per_session,
          "PTC_RUNNER_MCP_HTTP_MAX_IN_FLIGHT_PER_SESSION",
          @default_max_in_flight_per_session
        ),
      allow_unsafe_network:
        read_bool(
          args,
          :http_allow_unsafe_network,
          "PTC_RUNNER_MCP_HTTP_ALLOW_UNSAFE_NETWORK",
          false
        ),
      metrics?: read_bool(args, :http_metrics, "PTC_RUNNER_MCP_HTTP_METRICS", false),
      metrics_path:
        normalize_path(
          read_string(args, :http_metrics_path, "PTC_RUNNER_MCP_HTTP_METRICS_PATH", "/metrics")
        ),
      instance_label:
        read_string(args, :http_instance_label, "PTC_RUNNER_MCP_HTTP_INSTANCE_LABEL", hostname())
    }

    validate(cfg)
  end

  @doc false
  @spec loopback_host?(String.t()) :: boolean()
  def loopback_host?(host) when is_binary(host) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> host in ["localhost", "::1"]
    end
  end

  @doc false
  @spec token_min_bytes() :: pos_integer()
  def token_min_bytes, do: @token_min_bytes

  defp validate(%{enabled: false} = cfg), do: {:ok, cfg}

  defp validate(cfg) do
    with :ok <- validate_path_collisions(cfg),
         :ok <- validate_auth(cfg) do
      maybe_warn_single_token_caps(cfg)
      {:ok, cfg}
    end
  end

  defp validate_path_collisions(cfg) do
    paths = [cfg.path, "/health", "/ready", cfg.metrics_path]

    if Enum.uniq(paths) == paths do
      :ok
    else
      {:error, "HTTP paths must be distinct"}
    end
  end

  defp validate_auth(%{auth_token: token})
       when is_binary(token) and byte_size(token) < @token_min_bytes do
    {:error, "HTTP auth token must be at least #{@token_min_bytes} characters"}
  end

  defp validate_auth(%{auth_disabled: true, allow_unsafe_network: true}), do: :ok

  defp validate_auth(%{auth_disabled: true, host: host}) when is_binary(host),
    do: auth_disabled_loopback(host)

  defp validate_auth(%{auth_token: token}) when is_binary(token), do: :ok

  defp validate_auth(%{host: host}) do
    if loopback_host?(host) do
      :ok
    else
      {:error, "HTTP auth token is required for non-loopback binds"}
    end
  end

  defp auth_disabled_loopback(host) do
    if loopback_host?(host) do
      Log.log(:warn, "http_auth_disabled_loopback")
      :ok
    else
      {:error, "non-loopback unauthenticated HTTP requires --http-allow-unsafe-network"}
    end
  end

  defp maybe_warn_single_token_caps(%{
         auth_token: token,
         max_sessions: max_sessions,
         max_sessions_per_owner: max_per_owner
       })
       when is_binary(token) and max_per_owner < max_sessions do
    Log.log(:warn, "http_single_token_owner_cap_below_global", %{
      max_sessions: max_sessions,
      max_sessions_per_owner: max_per_owner
    })
  end

  defp maybe_warn_single_token_caps(_cfg), do: :ok

  defp read_string(args, key, env, default) do
    case env_or(args, key, env) do
      nil -> default
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp read_optional_string(args, key, env) do
    case env_or(args, key, env) do
      nil -> nil
      "" -> nil
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp read_int(args, key, env, default) do
    case env_or(args, key, env) do
      nil ->
        default

      n when is_integer(n) and n > 0 ->
        n

      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n > 0 -> n
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_bool(args, key, env, default) do
    case env_or(args, key, env) do
      nil -> default
      value when is_boolean(value) -> value
      value when is_binary(value) -> value |> String.downcase() |> String.trim() |> bool(default)
      _ -> default
    end
  end

  defp bool(value, _default) when value in ["1", "true", "yes", "on"], do: true
  defp bool(value, _default) when value in ["0", "false", "no", "off"], do: false
  defp bool(_value, default), do: default

  defp read_list(args, key, env) do
    values =
      args
      |> Map.get(key, [])
      |> List.wrap()

    env_values =
      case System.get_env(env) do
        nil -> []
        "" -> []
        raw -> String.split(raw, ",", trim: true)
      end

    (values ++ env_values)
    |> Enum.map(&to_string/1)
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp env_or(args, key, env) do
    case Map.fetch(args, key) do
      {:ok, value} -> value
      :error -> System.get_env(env)
    end
  end

  defp normalize_path(path) when is_binary(path) do
    if String.starts_with?(path, "/"), do: path, else: "/" <> path
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end
end
