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
    * `--program-timeout-ms <int>` / `PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS`
    * `--program-memory-limit-bytes <int>` / `PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES`
    * `--log-level <debug|info|warn|error>` / `PTC_RUNNER_MCP_LOG_LEVEL`
    * `--trace-dir <path>` / `PTC_RUNNER_MCP_TRACE_DIR`
    * `--trace-payloads <none|summary|full>` / `PTC_RUNNER_MCP_TRACE_PAYLOADS`
    * `--trace-max-files <int>` / `PTC_RUNNER_MCP_TRACE_MAX_FILES`

  Phase 0 of `Plans/ptc-runner-mcp-aggregator.md` (§11.6 / §9) wires
  the program-level limit flags with v1 defaults (1 s / 10 MB).
  Aggregator-only limits (`--upstream-call-timeout-ms`,
  `--max-upstream-response-bytes`, `--max-upstream-calls-per-program`)
  land in Phase 1a where they are actually consumed.

  Precedence (highest first): CLI flag, environment variable, default.

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

    upstreams = load_upstreams_config(args)
    apply_limits(args, aggregator?: upstreams != [])
    apply_trace_config(args)

    # Eagerly initialize the concurrency-gate atomics ref so that
    # concurrent first acquires cannot race on lazy persistent_term
    # creation (codex review of Phase 2).
    :ok = ConcurrencyGate.init()

    children = aggregator_children(upstreams) ++ stdio_children(args)

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
          program_timeout_ms: :integer,
          program_memory_limit_bytes: :integer,
          # Phase 1a aggregator-only flags (`Plans/ptc-runner-mcp-aggregator.md` §9).
          upstream_call_timeout_ms: :integer,
          max_upstream_response_bytes: :integer,
          max_upstream_calls_per_program: :integer,
          upstreams_config: :string,
          log_level: :string,
          trace_dir: :string,
          trace_payloads: :string,
          trace_max_files: :integer
        ]
      )

    Map.new(opts)
  end

  # Public-but-undocumented seam used by `Application.start/2` and by
  # the unit-test suite to verify CLI > env > mode-default precedence
  # per `Plans/ptc-runner-mcp-aggregator.md` §9 / §11.6. Returns `:ok`.
  #
  # The `aggregator?:` opt drives §11.6's "aggregator defaults only
  # when no explicit value provided" rule for `program_timeout_ms` and
  # `program_memory_limit_bytes`. CLI flag and env var always win;
  # the mode default fires only when neither was supplied.
  @doc false
  @spec apply_limits(map(), keyword()) :: :ok
  def apply_limits(args, opts \\ []) do
    aggregator? = Keyword.get(opts, :aggregator?, false)
    defaults = Limits.defaults()

    program_timeout_default =
      if aggregator?,
        do: Limits.aggregator_defaults().program_timeout_ms,
        else: defaults.program_timeout_ms

    program_memory_default =
      if aggregator?,
        do: Limits.aggregator_defaults().program_memory_limit_bytes,
        else: defaults.program_memory_limit_bytes

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
        ),
      program_timeout_ms:
        read_int(
          args,
          :program_timeout_ms,
          "PTC_RUNNER_MCP_PROGRAM_TIMEOUT_MS",
          program_timeout_default
        ),
      program_memory_limit_bytes:
        read_int(
          args,
          :program_memory_limit_bytes,
          "PTC_RUNNER_MCP_PROGRAM_MEMORY_LIMIT_BYTES",
          program_memory_default
        ),
      upstream_call_timeout_ms:
        read_int(
          args,
          :upstream_call_timeout_ms,
          "PTC_RUNNER_MCP_UPSTREAM_CALL_TIMEOUT_MS",
          defaults.upstream_call_timeout_ms
        ),
      max_upstream_response_bytes:
        read_int(
          args,
          :max_upstream_response_bytes,
          "PTC_RUNNER_MCP_MAX_UPSTREAM_RESPONSE_BYTES",
          # §9 enforce ≥1 floor: a sub-byte cap is degenerate. Limits
          # storage stays positive_integer; we trust read_int's positive
          # filter and rely on default if input is invalid.
          defaults.max_upstream_response_bytes
        ),
      max_upstream_calls_per_program:
        read_int(
          args,
          :max_upstream_calls_per_program,
          "PTC_RUNNER_MCP_MAX_UPSTREAM_CALLS_PER_PROGRAM",
          defaults.max_upstream_calls_per_program
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

  # Phase 1a: when at least one upstream is configured, start the
  # `Upstream.Supervisor` (which owns the registry GenServer + child
  # supervisor for upstream processes) so `tool/mcp-call` invocations
  # have a routing destination. When no upstreams are configured the
  # server runs in `:mcp_no_tools` mode and the upstream subsystem is
  # absent — `configured_aggregator_mode?/0` is `false`.
  defp aggregator_children([]), do: []

  defp aggregator_children(upstreams) when is_list(upstreams) do
    [{PtcRunnerMcp.Upstream.Supervisor, [upstreams: upstreams]}]
  end

  # Resolve the upstreams config per §5.1: flag → env → XDG default.
  # Returns a list of `%{name: ..., impl: ..., config: ...}` entries,
  # or `[]` when no source is found / the file is empty.
  #
  # Phase 1a parses the config file but Phase 1a's only impl is the
  # in-process Fake — production users without upstreams configured
  # never reach this code, and tests inject Fakes via the Registry
  # test API. Because §5.4 forbids fake registration via JSON, this
  # loader maps every entry to the (yet-to-be-shipped) Stdio impl
  # module name (`PtcRunnerMcp.Upstream.Stdio`); calling
  # `ensure_started/1` against such an entry will fail with
  # `:upstream_unavailable` until Phase 1b lands the Stdio impl.
  defp load_upstreams_config(args) do
    path =
      env_or(args, :upstreams_config, "PTC_RUNNER_MCP_UPSTREAMS", nil) ||
        xdg_default_path()

    case path do
      nil ->
        []

      path when is_binary(path) ->
        case File.read(path) do
          {:ok, body} ->
            parse_upstreams_body(body, path)

          {:error, :enoent} ->
            []

          {:error, reason} ->
            Log.log(:warn, "upstreams_config_read_failed", %{
              path: path,
              reason: to_string(:file.format_error(reason))
            })

            []
        end
    end
  end

  defp parse_upstreams_body("", _path), do: []

  defp parse_upstreams_body(body, path) do
    case Jason.decode(body) do
      {:ok, %{"upstreams" => map}} when is_map(map) and map_size(map) == 0 ->
        []

      {:ok, %{"upstreams" => map}} when is_map(map) ->
        Enum.map(map, fn {name, config} ->
          %{
            name: name,
            impl: PtcRunnerMcp.Upstream.Stdio,
            config: resolve_env_placeholders(config)
          }
        end)

      {:ok, _other} ->
        Log.log(:warn, "upstreams_config_invalid", %{
          path: path,
          reason: "missing top-level :upstreams key"
        })

        []

      {:error, reason} ->
        Log.log(:warn, "upstreams_config_invalid", %{
          path: path,
          reason: inspect(reason, limit: 50)
        })

        []
    end
  end

  defp resolve_env_placeholders(config) when is_map(config) do
    Map.new(config, fn {k, v} -> {k, resolve_env_placeholders(v)} end)
  end

  defp resolve_env_placeholders(list) when is_list(list) do
    Enum.map(list, &resolve_env_placeholders/1)
  end

  defp resolve_env_placeholders(value) when is_binary(value) do
    case Regex.run(~r/^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/, value) do
      [_, var] ->
        case System.get_env(var) do
          nil ->
            raise "upstreams_config: env var #{var} is not set (referenced as ${#{var}})"

          resolved ->
            resolved
        end

      nil ->
        value
    end
  end

  defp resolve_env_placeholders(value), do: value

  defp xdg_default_path do
    case System.get_env("HOME") do
      nil ->
        nil

      home ->
        path = Path.join([home, ".config", "ptc_runner_mcp", "upstreams.json"])
        if File.exists?(path), do: path, else: nil
    end
  end

  defp attach_stdio? do
    Application.get_env(:ptc_runner_mcp, :attach_stdio, true) and not in_test?()
  end

  defp in_test? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end
end
