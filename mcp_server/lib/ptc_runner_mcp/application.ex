defmodule PtcRunnerMcp.Application do
  @moduledoc """
  OTP entry point for the PtcRunner MCP server.

  Per `Plans/ptc-runner-mcp-server.md` § 5.2 / § 6.4, this application
  starts a single supervisor that owns the stdio reader. CLI flags
  and environment variables are read once at boot:

    * `--max-frame-bytes <int>` / `PTC_RUNNER_MCP_MAX_FRAME_BYTES`
    * `--max-program-bytes <int>` / `PTC_RUNNER_MCP_MAX_PROGRAM_BYTES`
    * `--max-concurrent-calls <int>` / `PTC_RUNNER_MCP_MAX_CONCURRENT_CALLS`
    * `--log-level <debug|info|warn|error>` / `PTC_RUNNER_MCP_LOG_LEVEL`

  In test environments (`Mix.env() == :test`) the supervision tree is
  empty — tests start `PtcRunnerMcp.Stdio` directly with their own IO
  device. Production starts the stdio loop attached to `:stdio`.
  """

  use Application

  alias PtcRunnerMcp.{ConcurrencyGate, Limits, Log}

  @impl Application
  def start(_type, _args) do
    args = parse_args(System.argv())

    Log.set_level(env_or(args, :log_level, "PTC_RUNNER_MCP_LOG_LEVEL", "info"))
    apply_limits(args)

    # Eagerly initialize the concurrency-gate atomics ref so that
    # concurrent first acquires cannot race on lazy persistent_term
    # creation (codex review of Phase 2).
    :ok = ConcurrencyGate.init()

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
          max_program_bytes: :integer,
          max_concurrent_calls: :integer,
          log_level: :string
        ]
      )

    Map.new(opts)
  end

  defp apply_limits(args) do
    defaults = Limits.defaults()

    overrides = %{
      max_frame_bytes:
        read_int(
          args,
          :max_frame_bytes,
          "PTC_RUNNER_MCP_MAX_FRAME_BYTES",
          defaults.max_frame_bytes
        ),
      max_program_bytes:
        read_int(
          args,
          :max_program_bytes,
          "PTC_RUNNER_MCP_MAX_PROGRAM_BYTES",
          defaults.max_program_bytes
        ),
      max_concurrent_calls:
        read_int(
          args,
          :max_concurrent_calls,
          "PTC_RUNNER_MCP_MAX_CONCURRENT_CALLS",
          defaults.max_concurrent_calls
        )
    }

    Limits.set(overrides)
  end

  defp read_int(args, key, env_name, default) do
    case env_or(args, key, env_name, nil) do
      nil ->
        default

      n when is_integer(n) and n > 0 ->
        n

      bin when is_binary(bin) ->
        case Integer.parse(bin) do
          {n, _} when n > 0 -> n
          _ -> default
        end

      _ ->
        default
    end
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
