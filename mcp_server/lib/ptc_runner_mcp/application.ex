defmodule PtcRunnerMcp.Application do
  @moduledoc """
  OTP entry point for the PtcRunner MCP server.

  Per `Plans/ptc-runner-mcp-server.md` § 5.2 / § 6.4, this application
  starts a single supervisor that owns the stdio reader. CLI flags
  and environment variables are read once at boot:

    * `--max-frame-bytes <int>` / `PTC_RUNNER_MCP_MAX_FRAME_BYTES`
    * `--log-level <debug|info|warn|error>` / `PTC_RUNNER_MCP_LOG_LEVEL`

  In test environments (`Mix.env() == :test`) the supervision tree is
  empty — tests start `PtcRunnerMcp.Stdio` directly with their own IO
  device. Production starts the stdio loop attached to `:stdio`.
  """

  use Application

  alias PtcRunnerMcp.{Limits, Log}

  @impl Application
  def start(_type, _args) do
    args = parse_args(System.argv())

    Log.set_level(env_or(args, :log_level, "PTC_RUNNER_MCP_LOG_LEVEL", "info"))
    apply_limits(args)

    children = stdio_children(args)

    opts = [strategy: :one_for_one, name: PtcRunnerMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # ----------------------------------------------------------------
  # Configuration plumbing
  # ----------------------------------------------------------------

  @doc false
  def parse_args(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [
          max_frame_bytes: :integer,
          log_level: :string
        ]
      )

    Map.new(opts)
  end

  defp apply_limits(args) do
    max_frame =
      case env_or(args, :max_frame_bytes, "PTC_RUNNER_MCP_MAX_FRAME_BYTES", nil) do
        nil ->
          Limits.defaults().max_frame_bytes

        n when is_integer(n) ->
          n

        bin when is_binary(bin) ->
          case Integer.parse(bin) do
            {n, _} -> n
            :error -> Limits.defaults().max_frame_bytes
          end
      end

    Limits.set(%{max_frame_bytes: max_frame})
  end

  defp env_or(args, key, env_name, default) do
    case Map.fetch(args, key) do
      {:ok, v} ->
        v

      :error ->
        case System.get_env(env_name) do
          nil -> default
          "" -> default
          v -> v
        end
    end
  end

  # In :test, the application starts an empty supervisor; tests
  # construct the stdio loop themselves with a fake IO device.
  defp stdio_children(_args) do
    if attach_stdio?() do
      [{PtcRunnerMcp.Stdio, []}]
    else
      []
    end
  end

  defp attach_stdio? do
    Application.get_env(:ptc_runner_mcp, :attach_stdio, true) and not in_test?()
  end

  defp in_test? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end
end
