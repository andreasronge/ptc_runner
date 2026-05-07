defmodule PtcRunnerMcp.Application do
  @moduledoc """
  OTP entry point for the PtcRunner MCP server.

  Per `Plans/ptc-runner-mcp-server.md` § 5.2 / § 6.4, this application
  starts a single supervisor that owns the stdio reader. CLI flags
  and environment variables are read once at boot:

    * `--max-frame-bytes <int>` / `PTC_RUNNER_MCP_MAX_FRAME_BYTES`
    * `--max-program-bytes <int>` / `PTC_RUNNER_MCP_MAX_PROGRAM_BYTES`
    * `--max-context-bytes <int>` / `PTC_RUNNER_MCP_MAX_CONTEXT_BYTES`
    * `--max-concurrent-calls <int>` / `PTC_RUNNER_MCP_MAX_CONCURRENT_CALLS`
    * `--log-level <debug|info|warn|error>` / `PTC_RUNNER_MCP_LOG_LEVEL`
    * `--trace-dir <path>` / `PTC_RUNNER_MCP_TRACE_DIR`
    * `--trace-payloads <none|summary|full>` / `PTC_RUNNER_MCP_TRACE_PAYLOADS`
    * `--trace-max-files <int>` / `PTC_RUNNER_MCP_TRACE_MAX_FILES`

  In test environments (`Mix.env() == :test`) the supervision tree is
  empty — tests start `PtcRunnerMcp.Stdio` directly with their own IO
  device. Production starts the stdio loop attached to `:stdio`.
  """

  use Application

  alias PtcRunnerMcp.{ConcurrencyGate, Limits, Log, TraceConfig, TraceHandler}

  @impl Application
  def start(_type, _args) do
    args = parse_args(System.argv())

    Log.set_level(env_or(args, :log_level, "PTC_RUNNER_MCP_LOG_LEVEL", "info"))
    apply_limits(args)
    apply_trace_config(args)

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
          max_context_bytes: :integer,
          max_concurrent_calls: :integer,
          log_level: :string,
          trace_dir: :string,
          trace_payloads: :string,
          trace_max_files: :integer
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
      max_context_bytes:
        read_int(
          args,
          :max_context_bytes,
          "PTC_RUNNER_MCP_MAX_CONTEXT_BYTES",
          defaults.max_context_bytes
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

  # Per § 6.6 / § 6.9 / § 6.10: parse trace flags, store in
  # `TraceConfig`, and attach the telemetry handler ONLY when
  # `--trace-dir` is set.
  defp apply_trace_config(args) do
    trace_dir =
      case env_or(args, :trace_dir, "PTC_RUNNER_MCP_TRACE_DIR", nil) do
        nil -> nil
        "" -> nil
        v when is_binary(v) -> v
      end

    payloads = parse_trace_payloads(args)

    max_files =
      read_int(
        args,
        :trace_max_files,
        "PTC_RUNNER_MCP_TRACE_MAX_FILES",
        TraceConfig.defaults().trace_max_files
      )

    TraceConfig.set(%{
      trace_dir: trace_dir,
      trace_payloads: payloads,
      trace_max_files: max_files
    })

    if is_nil(trace_dir) do
      # Tracing disabled: ensure no stale handler is attached (relevant
      # for hot-restarts in tests / development reloads).
      TraceHandler.detach()
    else
      TraceHandler.attach()
    end

    :ok
  end

  defp parse_trace_payloads(args) do
    raw = env_or(args, :trace_payloads, "PTC_RUNNER_MCP_TRACE_PAYLOADS", nil)

    case raw do
      nil ->
        TraceConfig.defaults().trace_payloads

      "" ->
        TraceConfig.defaults().trace_payloads

      value ->
        case TraceConfig.parse_payloads(value) do
          {:ok, level} ->
            level

          :error ->
            Log.log(:warn, "trace_payloads_invalid", %{
              value: to_string(value),
              fallback: "summary"
            })

            :summary
        end
    end
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
