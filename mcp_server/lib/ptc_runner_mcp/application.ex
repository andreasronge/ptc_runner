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
    * `--aggregator-read-only` / `PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY`
    * `--log-level <debug|info|warn|error>` / `PTC_RUNNER_MCP_LOG_LEVEL`
    * `--trace-dir <path>` / `PTC_RUNNER_MCP_TRACE_DIR`
    * `--trace-payloads <none|summary|full>` / `PTC_RUNNER_MCP_TRACE_PAYLOADS`
    * `--trace-max-files <int>` / `PTC_RUNNER_MCP_TRACE_MAX_FILES`
    * `--agentic-max-turns <int>` / `PTC_RUNNER_MCP_AGENTIC_MAX_TURNS`
    * `--agentic-retry-turns <int>` / `PTC_RUNNER_MCP_AGENTIC_RETRY_TURNS`
    * `--agentic-allow-writes` / `PTC_RUNNER_MCP_AGENTIC_ALLOW_WRITES`
    * `--agentic-subagent-config <path>` / `PTC_RUNNER_MCP_AGENTIC_SUBAGENT_CONFIG`
    * `--agentic-capability-summary-max-bytes <int>` / `PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY_MAX_BYTES`
    * `--agentic-capability-summary <path>` / `PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY`
    * `--debug-tool` / `PTC_RUNNER_MCP_DEBUG_TOOL`
    * `--debug-ring-size <int>` / `PTC_RUNNER_MCP_DEBUG_RING_SIZE`
    * `--max-debug-response-bytes <int>` / `PTC_RUNNER_MCP_MAX_DEBUG_RESPONSE_BYTES`
    * `--response-profile <slim|structured|debug>` / `PTC_RUNNER_MCP_RESPONSE_PROFILE`

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

  alias PtcRunnerMcp.{
    AgenticConfig,
    AggregatorConfig,
    CatalogConfig,
    ConcurrencyGate,
    Credentials,
    DebugConfig,
    Limits,
    Log,
    ResponseProfile,
    Sessions,
    TraceConfig,
    TraceHandler
  }

  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig

  @impl Application
  def start(_type, _args) do
    PtcRunner.Dotenv.load()
    args = parse_args(System.argv())

    Log.set_level(env_or(args, :log_level, "PTC_RUNNER_MCP_LOG_LEVEL", "info"))

    %{upstreams: upstreams, credentials: bindings} = load_aggregator_config(args)
    apply_aggregator_config(args)
    apply_catalog_config(args)
    apply_agentic_config(args)
    apply_debug_config(args)
    apply_response_profile(args)
    apply_sessions_config(args)
    validate_agentic_boot!(upstreams)
    apply_limits(args, aggregator?: upstreams != [])
    apply_trace_config(args)

    if AgenticConfig.enabled?() and upstreams == [] do
      Log.log(:warn, "agentic_without_aggregator", %{
        message: "agentic mode is enabled but no upstream MCP servers are configured"
      })
    end

    # Eagerly initialize the concurrency-gate atomics ref so that
    # concurrent first acquires cannot race on lazy persistent_term
    # creation (codex review of Phase 2).
    :ok = ConcurrencyGate.init()

    # In `:test` the application supervisor is empty — tests construct
    # `Credentials` / `Stdio` / `Upstream.Supervisor` instances under
    # unique names. Returning an empty child list keeps the named ETS
    # redaction table free for test-owned `Credentials` instances.
    children =
      if attach_stdio?() do
        build_children(upstreams, bindings, args)
      else
        []
      end

    # `:rest_for_one` per `Plans/http-transport-credentials.md` §7.1.
    # `Credentials` is the first child; if it crashes we want every
    # later child (HTTP upstream impls in Phase 2/3) restarted so
    # they re-handshake against the freshly-rebuilt redaction set.
    opts = [strategy: :rest_for_one, name: PtcRunnerMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Compose the production supervisor child list. Public-but-undocumented
  # seam so tests can inspect ordering without running `start/2`.
  # Order matters for `:rest_for_one`: `Credentials` MUST come before
  # `Upstream.Supervisor` per §7.1.
  #
  # `Credentials` is the FIRST child. Per §7.1 it is started whenever
  # the parsed config has a `credentials:` block OR any HTTP upstream;
  # Phase 1 simplifies by starting it unconditionally so the supervisor-
  # ordering invariant holds even for stdio-only configs (`bindings:
  # %{}` is harmless). This also guarantees the named ETS redaction
  # table is alive before any worker tries to read it via
  # `Credentials.Redactor.scrub/1`.
  @doc false
  @spec build_children([map()], %{String.t() => Credentials.Binding.t()}, map()) ::
          [Supervisor.child_spec() | {module(), term()}]
  def build_children(upstreams, bindings, args) do
    [{Credentials, [bindings: bindings]}] ++
      aggregator_children(upstreams) ++
      session_children() ++
      stdio_children(args)
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
          aggregator_read_only: :boolean,
          catalog_mode: :string,
          catalog_inline_max_chars: :integer,
          catalog_inline_max_tools: :integer,
          max_catalog_ops_per_program: :integer,
          max_catalog_result_bytes: :integer,
          agentic: :boolean,
          agentic_model: :string,
          agentic_task_timeout_ms: :integer,
          agentic_planner_timeout_ms: :integer,
          agentic_max_output_tokens: :integer,
          agentic_max_result_bytes: :integer,
          agentic_include_program: :boolean,
          agentic_trace_prompts: :boolean,
          agentic_max_turns: :integer,
          agentic_retry_turns: :integer,
          agentic_allow_writes: :boolean,
          agentic_subagent_config: :string,
          agentic_capability_summary_max_bytes: :integer,
          agentic_capability_summary: :string,
          upstreams_config: :string,
          sessions: :boolean,
          max_sessions: :integer,
          max_sessions_per_owner: :integer,
          session_ttl_ms: :integer,
          session_idle_timeout_ms: :integer,
          max_session_memory_bytes: :integer,
          max_session_binding_bytes: :integer,
          max_session_bindings: :integer,
          max_session_history_entry_bytes: :integer,
          max_session_print_entries: :integer,
          max_session_print_bytes: :integer,
          max_session_tool_call_entries: :integer,
          max_session_tool_call_bytes: :integer,
          max_session_upstream_call_entries: :integer,
          max_session_upstream_call_bytes: :integer,
          log_level: :string,
          trace_dir: :string,
          trace_payloads: :string,
          trace_max_files: :integer,
          # `Plans/ptc-runner-mcp-debug-tool.md` § 4 — opt-in diagnostics tool.
          debug_tool: :boolean,
          debug_ring_size: :integer,
          max_debug_response_bytes: :integer,
          response_profile: :string
        ]
      )

    Map.new(opts)
  end

  # Public-but-undocumented seam used by tests to verify CLI > env >
  # default precedence for non-limit aggregator behavior.
  @doc false
  @spec apply_aggregator_config(map()) :: :ok
  def apply_aggregator_config(args) when is_map(args) do
    AggregatorConfig.set(%{
      read_only:
        read_bool(
          args,
          :aggregator_read_only,
          "PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY",
          AggregatorConfig.defaults().read_only
        )
    })
  end

  @doc false
  @spec apply_catalog_config(map()) :: :ok
  def apply_catalog_config(args) when is_map(args) do
    defaults = CatalogConfig.defaults()

    catalog_mode = parse_catalog_mode(args, defaults.catalog_mode)

    CatalogConfig.set(%{
      catalog_mode: catalog_mode,
      catalog_inline_max_chars:
        read_int(
          args,
          :catalog_inline_max_chars,
          "PTC_RUNNER_MCP_CATALOG_INLINE_MAX_CHARS",
          defaults.catalog_inline_max_chars
        ),
      catalog_inline_max_tools:
        read_int(
          args,
          :catalog_inline_max_tools,
          "PTC_RUNNER_MCP_CATALOG_INLINE_MAX_TOOLS",
          defaults.catalog_inline_max_tools
        ),
      max_catalog_ops_per_program:
        read_int(
          args,
          :max_catalog_ops_per_program,
          "PTC_RUNNER_MCP_MAX_CATALOG_OPS_PER_PROGRAM",
          defaults.max_catalog_ops_per_program
        ),
      max_catalog_result_bytes:
        read_int(
          args,
          :max_catalog_result_bytes,
          "PTC_RUNNER_MCP_MAX_CATALOG_RESULT_BYTES",
          defaults.max_catalog_result_bytes
        )
    })
  end

  defp parse_catalog_mode(args, default) do
    raw = env_or(args, :catalog_mode, "PTC_RUNNER_MCP_CATALOG_MODE", nil)

    case raw do
      nil ->
        default

      value when is_binary(value) ->
        case CatalogConfig.parse_mode(value) do
          {:ok, mode} ->
            mode

          :error ->
            Log.log(:warn, "catalog_mode_invalid", %{
              value: value,
              fallback: "auto"
            })

            :auto
        end

      _ ->
        default
    end
  end

  # Public-but-undocumented seam used by tests to verify CLI > env >
  # default precedence for the opt-in `ptc_debug` tool config
  # (`Plans/ptc-runner-mcp-debug-tool.md` § 4).
  @doc false
  @spec apply_debug_config(map()) :: :ok
  def apply_debug_config(args) when is_map(args) do
    defaults = DebugConfig.defaults()

    enabled =
      read_bool(args, :debug_tool, "PTC_RUNNER_MCP_DEBUG_TOOL", defaults.enabled)

    requested_ring_size =
      read_int_raw(
        args,
        :debug_ring_size,
        "PTC_RUNNER_MCP_DEBUG_RING_SIZE",
        defaults.ring_size
      )

    {ring_size, clamped?} = DebugConfig.clamp_ring_size(requested_ring_size)

    if clamped? do
      {lo, hi} = DebugConfig.ring_size_bounds()

      Log.log(:warn, "debug_ring_size_clamped", %{
        requested: requested_ring_size,
        clamped_to: ring_size,
        min: lo,
        max: hi
      })
    end

    requested_max_response_bytes =
      read_int_raw(
        args,
        :max_debug_response_bytes,
        "PTC_RUNNER_MCP_MAX_DEBUG_RESPONSE_BYTES",
        defaults.max_response_bytes
      )

    {max_response_bytes, mrb_clamped?} =
      DebugConfig.clamp_max_response_bytes(requested_max_response_bytes)

    if mrb_clamped? do
      Log.log(:warn, "max_debug_response_bytes_clamped", %{
        requested: requested_max_response_bytes,
        clamped_to: max_response_bytes,
        min: DebugConfig.max_response_bytes_min()
      })
    end

    :ok =
      DebugConfig.set(%{
        enabled: enabled,
        ring_size: ring_size,
        max_response_bytes: max_response_bytes
      })

    if enabled do
      Log.log(:info, "debug_config", %{
        ring_size: ring_size,
        max_response_bytes: max_response_bytes
      })
    end

    :ok
  end

  @doc false
  @spec apply_response_profile(map()) :: :ok
  def apply_response_profile(args) when is_map(args) do
    ResponseProfile.set(ResponseProfile.resolve(args))
  end

  @doc false
  @spec apply_agentic_config(map()) :: :ok
  def apply_agentic_config(args) when is_map(args) do
    defaults = AgenticConfig.defaults()

    subagent_config_path =
      env_or(
        args,
        :agentic_subagent_config,
        "PTC_RUNNER_MCP_AGENTIC_SUBAGENT_CONFIG",
        defaults.subagent_config_path
      )

    subagent_config = AgenticConfig.load_subagent_config!(subagent_config_path)
    source_keys = agentic_source_keys(args, subagent_config)

    capability_summary_max_bytes =
      read_int(
        args,
        :agentic_capability_summary_max_bytes,
        "PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY_MAX_BYTES",
        defaults.capability_summary_max_bytes
      )

    capability_summary_path =
      env_or(
        args,
        :agentic_capability_summary,
        "PTC_RUNNER_MCP_AGENTIC_CAPABILITY_SUMMARY",
        defaults.capability_summary_path
      )

    capability_summary =
      AgenticConfig.load_capability_summary!(
        capability_summary_path,
        capability_summary_max_bytes
      )

    config = %{
      enabled: read_bool(args, :agentic, "PTC_RUNNER_MCP_AGENTIC", defaults.enabled),
      model: env_or(args, :agentic_model, "PTC_RUNNER_MCP_AGENTIC_MODEL", defaults.model),
      task_timeout_ms:
        read_int(
          args,
          :agentic_task_timeout_ms,
          "PTC_RUNNER_MCP_AGENTIC_TASK_TIMEOUT_MS",
          defaults.task_timeout_ms
        ),
      planner_timeout_ms:
        read_int(
          args,
          :agentic_planner_timeout_ms,
          "PTC_RUNNER_MCP_AGENTIC_PLANNER_TIMEOUT_MS",
          defaults.planner_timeout_ms
        ),
      max_output_tokens:
        read_int(
          args,
          :agentic_max_output_tokens,
          "PTC_RUNNER_MCP_AGENTIC_MAX_OUTPUT_TOKENS",
          defaults.max_output_tokens
        ),
      max_result_bytes:
        read_int(
          args,
          :agentic_max_result_bytes,
          "PTC_RUNNER_MCP_AGENTIC_MAX_RESULT_BYTES",
          defaults.max_result_bytes
        ),
      include_program:
        read_bool(
          args,
          :agentic_include_program,
          "PTC_RUNNER_MCP_AGENTIC_INCLUDE_PROGRAM",
          defaults.include_program
        ),
      trace_prompts:
        read_bool(
          args,
          :agentic_trace_prompts,
          "PTC_RUNNER_MCP_AGENTIC_TRACE_PROMPTS",
          defaults.trace_prompts
        ),
      max_turns:
        read_int(
          args,
          :agentic_max_turns,
          "PTC_RUNNER_MCP_AGENTIC_MAX_TURNS",
          Map.get(subagent_config, :max_turns, defaults.max_turns)
        ),
      retry_turns:
        read_non_neg_int(
          args,
          :agentic_retry_turns,
          "PTC_RUNNER_MCP_AGENTIC_RETRY_TURNS",
          Map.get(subagent_config, :retry_turns, defaults.retry_turns)
        ),
      allow_writes:
        read_bool(
          args,
          :agentic_allow_writes,
          "PTC_RUNNER_MCP_AGENTIC_ALLOW_WRITES",
          defaults.allow_writes
        ),
      subagent_config_path: subagent_config_path,
      capability_summary_max_bytes: capability_summary_max_bytes,
      capability_summary_path: capability_summary_path,
      capability_summary: capability_summary,
      system_prompt:
        Map.merge(
          defaults.system_prompt,
          Map.get(subagent_config, :system_prompt, %{})
        )
    }

    :ok = AgenticConfig.set(config)
    AgenticConfig.log_boot(AgenticConfig.get(), source_keys)
  end

  @doc false
  @spec validate_agentic_boot!([map()]) :: :ok
  def validate_agentic_boot!(upstreams) when is_list(upstreams) do
    cfg = AgenticConfig.get()

    cond do
      cfg.allow_writes and not cfg.enabled ->
        raise """
        agentic configuration invalid: --agentic-allow-writes requires --agentic.
        """

      cfg.enabled and upstreams != [] and not AggregatorConfig.read_only?() and
          not cfg.allow_writes ->
        raise """
        agentic configuration invalid: configured upstream access is not asserted read-only.

        Set --aggregator-read-only if all configured upstream tools are operator-asserted read-only,
        or set --agentic-allow-writes to explicitly enable write-capable agentic configuration validation.
        """

      true ->
        :ok
    end
  end

  @doc false
  @spec apply_sessions_config(map()) :: :ok
  def apply_sessions_config(args) when is_map(args) do
    defaults = SessionsConfig.defaults()

    SessionsConfig.set(%{
      enabled: read_bool(args, :sessions, "PTC_RUNNER_MCP_SESSIONS", defaults.enabled),
      max_sessions:
        read_int(args, :max_sessions, "PTC_RUNNER_MCP_MAX_SESSIONS", defaults.max_sessions),
      max_sessions_per_owner:
        read_int(
          args,
          :max_sessions_per_owner,
          "PTC_RUNNER_MCP_MAX_SESSIONS_PER_OWNER",
          defaults.max_sessions_per_owner
        ),
      session_ttl_ms:
        read_int(args, :session_ttl_ms, "PTC_RUNNER_MCP_SESSION_TTL_MS", defaults.session_ttl_ms),
      session_idle_timeout_ms:
        read_int(
          args,
          :session_idle_timeout_ms,
          "PTC_RUNNER_MCP_SESSION_IDLE_TIMEOUT_MS",
          defaults.session_idle_timeout_ms
        ),
      max_session_memory_bytes:
        read_int(
          args,
          :max_session_memory_bytes,
          "PTC_RUNNER_MCP_MAX_SESSION_MEMORY_BYTES",
          defaults.max_session_memory_bytes
        ),
      max_session_binding_bytes:
        read_int(
          args,
          :max_session_binding_bytes,
          "PTC_RUNNER_MCP_MAX_SESSION_BINDING_BYTES",
          defaults.max_session_binding_bytes
        ),
      max_session_bindings:
        read_int(
          args,
          :max_session_bindings,
          "PTC_RUNNER_MCP_MAX_SESSION_BINDINGS",
          defaults.max_session_bindings
        ),
      max_session_history_entry_bytes:
        read_int(
          args,
          :max_session_history_entry_bytes,
          "PTC_RUNNER_MCP_MAX_SESSION_HISTORY_ENTRY_BYTES",
          defaults.max_session_history_entry_bytes
        ),
      max_session_print_entries:
        read_int(
          args,
          :max_session_print_entries,
          "PTC_RUNNER_MCP_MAX_SESSION_PRINT_ENTRIES",
          defaults.max_session_print_entries
        ),
      max_session_print_bytes:
        read_int(
          args,
          :max_session_print_bytes,
          "PTC_RUNNER_MCP_MAX_SESSION_PRINT_BYTES",
          defaults.max_session_print_bytes
        ),
      max_session_tool_call_entries:
        read_int(
          args,
          :max_session_tool_call_entries,
          "PTC_RUNNER_MCP_MAX_SESSION_TOOL_CALL_ENTRIES",
          defaults.max_session_tool_call_entries
        ),
      max_session_tool_call_bytes:
        read_int(
          args,
          :max_session_tool_call_bytes,
          "PTC_RUNNER_MCP_MAX_SESSION_TOOL_CALL_BYTES",
          defaults.max_session_tool_call_bytes
        ),
      max_session_upstream_call_entries:
        read_int(
          args,
          :max_session_upstream_call_entries,
          "PTC_RUNNER_MCP_MAX_SESSION_UPSTREAM_CALL_ENTRIES",
          defaults.max_session_upstream_call_entries
        ),
      max_session_upstream_call_bytes:
        read_int(
          args,
          :max_session_upstream_call_bytes,
          "PTC_RUNNER_MCP_MAX_SESSION_UPSTREAM_CALL_BYTES",
          defaults.max_session_upstream_call_bytes
        )
    })
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

  # Like `read_int/4` but does NOT reject non-positive values: used for options
  # that have their own clamp/floor (debug ring size, debug response cap), so an
  # operator's `0`/negative reaches the clamp (and its `warn` log) instead of
  # being silently swapped for the default. Falls back to `default` only when
  # the value is absent or not an integer at all.
  defp read_int_raw(args, key, env_name, default) do
    case env_or(args, key, env_name, nil) do
      nil ->
        default

      n when is_integer(n) ->
        n

      bin when is_binary(bin) ->
        case Integer.parse(bin) do
          {n, _} -> n
          :error -> default
        end

      _ ->
        default
    end
  end

  defp read_non_neg_int(args, key, env_name, default) do
    case env_or(args, key, env_name, nil) do
      nil ->
        default

      n when is_integer(n) and n >= 0 ->
        n

      bin when is_binary(bin) ->
        case Integer.parse(bin) do
          {n, _} when n >= 0 -> n
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_bool(args, key, env_name, default) do
    case env_or(args, key, env_name, nil) do
      nil -> default
      value when is_boolean(value) -> value
      value when is_binary(value) -> parse_bool(value, default)
      _ -> default
    end
  end

  defp parse_bool(value, default) do
    case String.downcase(String.trim(value)) do
      "1" -> true
      "true" -> true
      "yes" -> true
      "on" -> true
      "0" -> false
      "false" -> false
      "no" -> false
      "off" -> false
      _ -> default
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

  defp agentic_source_keys(args, subagent_config) do
    %{
      max_turns:
        agentic_value_source(
          args,
          :agentic_max_turns,
          "PTC_RUNNER_MCP_AGENTIC_MAX_TURNS",
          subagent_config,
          :max_turns
        ),
      retry_turns:
        agentic_value_source(
          args,
          :agentic_retry_turns,
          "PTC_RUNNER_MCP_AGENTIC_RETRY_TURNS",
          subagent_config,
          :retry_turns
        ),
      allow_writes:
        direct_value_source(args, :agentic_allow_writes, "PTC_RUNNER_MCP_AGENTIC_ALLOW_WRITES"),
      system_prompt_prefix: system_prompt_source(subagent_config, :prefix),
      system_prompt_suffix: system_prompt_source(subagent_config, :suffix)
    }
  end

  defp agentic_value_source(args, arg_key, env_name, config, config_key) do
    direct_value_source(args, arg_key, env_name) ||
      if Map.has_key?(config, config_key), do: "config_file", else: nil
  end

  defp direct_value_source(args, key, env_name) do
    cond do
      Map.has_key?(args, key) -> "cli"
      System.get_env(env_name) not in [nil, ""] -> "env"
      true -> nil
    end
  end

  defp system_prompt_source(%{system_prompt: prompt}, key) when is_map(prompt) do
    if Map.has_key?(prompt, key), do: "config_file", else: nil
  end

  defp system_prompt_source(_config, _key), do: nil

  # In :test, the application starts an empty supervisor; tests
  # construct the stdio loop themselves with a fake IO device.
  #
  # The `ptc_debug` ring buffer (`DebugBuffer`) is supervised here too,
  # but only when `--debug-tool` is set. It is listed **last** so that
  # under `:rest_for_one` a `DebugBuffer` crash restarts nothing after
  # it — an optional diagnostics failure must degrade to "no
  # diagnostics", never to a client-visible stdio disconnect.
  defp stdio_children(_args) do
    if attach_stdio?() do
      [{PtcRunnerMcp.Stdio, []}] ++ debug_children()
    else
      []
    end
  end

  defp debug_children do
    if DebugConfig.enabled?() do
      [{PtcRunnerMcp.DebugBuffer, [ring_size: DebugConfig.ring_size()]}]
    else
      []
    end
  end

  defp session_children do
    if SessionsConfig.enabled?() do
      Sessions.child_specs()
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
  # Returns a list of `%{name: ..., impl: ..., config: ..., metadata: ...}`
  # entries, or `[]` when no source is found / the file is empty.
  #
  # Phase 1a parses the config file but Phase 1a's only impl is the
  # in-process Fake — production users without upstreams configured
  # never reach this code, and tests inject Fakes via the Registry
  # test API. Because §5.4 forbids fake registration via JSON, this
  # loader maps every entry to the (yet-to-be-shipped) Stdio impl
  # module name (`PtcRunnerMcp.Upstream.Stdio`); calling
  # `ensure_started/1` against such an entry will fail with
  # `:upstream_unavailable` until Phase 1b lands the Stdio impl.
  #
  # Returns just the upstreams list. Callers that need the parsed
  # `credentials:` block use `load_aggregator_config/1` instead.
  @doc false
  @spec load_upstreams_config(map()) :: [
          %{name: String.t(), impl: module(), config: map(), metadata: map()}
        ]
  def load_upstreams_config(args) do
    load_aggregator_config(args).upstreams
  end

  # Aggregator-shaped loader per `Plans/http-transport-credentials.md`
  # §7.1: returns `%{upstreams: entries, credentials: bindings}` where
  # `bindings` is the parsed `credentials:` block (a `%{name => Binding}`
  # map; empty when the block is absent). The cross-reference validator
  # (§5.5 #1) runs here before this function returns so `start/2`
  # never sees a config that points at an unknown binding.
  @doc false
  @spec load_aggregator_config(map()) :: %{
          upstreams: [%{name: String.t(), impl: module(), config: map(), metadata: map()}],
          credentials: %{String.t() => Credentials.Binding.t()}
        }
  def load_aggregator_config(args) do
    path =
      env_or(args, :upstreams_config, "PTC_RUNNER_MCP_UPSTREAMS", nil) ||
        xdg_default_path()

    case path do
      nil ->
        %{upstreams: [], credentials: %{}}

      path when is_binary(path) ->
        case File.read(path) do
          {:ok, body} ->
            parse_aggregator_body(body, path)

          {:error, :enoent} ->
            %{upstreams: [], credentials: %{}}

          {:error, reason} ->
            Log.log(:warn, "upstreams_config_read_failed", %{
              path: path,
              reason: to_string(:file.format_error(reason))
            })

            %{upstreams: [], credentials: %{}}
        end
    end
  end

  defp parse_aggregator_body("", _path), do: %{upstreams: [], credentials: %{}}

  defp parse_aggregator_body(body, path) do
    case Jason.decode(body) do
      {:ok, %{"upstreams" => map} = decoded} when is_map(map) ->
        bindings = parse_credentials_block!(decoded, path)
        entries = parse_upstream_entries(map, path)
        :ok = validate_auth_binding_refs!(map, bindings, path)
        # §4.5: HTTP upstreams require `:req` to be loaded. Phase 1
        # configs are stdio-only and `transport:` is absent on every
        # entry, so this check is a no-op for v1 deployments. Phase 2E
        # adds full `transport: "http"` parsing (URL / proxy / insecure
        # gates); 2A only checks dep presence.
        :ok = check_http_deps!(map, path)
        %{upstreams: entries, credentials: bindings}

      {:ok, _other} ->
        Log.log(:warn, "upstreams_config_invalid", %{
          path: path,
          reason: "missing top-level :upstreams key"
        })

        %{upstreams: [], credentials: %{}}

      {:error, reason} ->
        Log.log(:warn, "upstreams_config_invalid", %{
          path: path,
          reason: inspect(reason, limit: 50)
        })

        %{upstreams: [], credentials: %{}}
    end
  end

  defp parse_upstream_entries(map, _path) when map_size(map) == 0, do: []

  defp parse_upstream_entries(map, path) do
    entries =
      Enum.map(map, fn {name, config} ->
        parse_upstream_entry(name, config, path)
      end)

    # §5.3 self-as-upstream rejection. Fail fast — the server
    # MUST NOT start with a config that would recursively spawn
    # itself. Codex review of `fe72ff6` flagged that without
    # this guard, a misconfigured deploy hits the recursion at
    # the Stdio impl level (now actually wired in Phase 1b).
    :ok = reject_self_as_upstream!(entries, path)

    entries
  end

  # Phase 2E: dispatch on the `transport:` field. Stdio is the default
  # (transport absent → stdio, preserving Phase 1 behavior). HTTP routes
  # through `parse_http_upstream/3`. Any other value is a loud raise so
  # operators get a clear error rather than a silent stdio fallback.
  defp parse_upstream_entry(name, config, path) when is_map(config) do
    case Map.get(config, "transport") do
      nil ->
        stdio_entry(name, config)

      "stdio" ->
        stdio_entry(name, config)

      "http" ->
        parse_http_upstream(name, config, path)

      other ->
        raise """
        upstreams_config: upstream '#{name}' has unknown transport '#{inspect(other)}'.

        Supported transports: "stdio" (default if absent), "http".

        Source: #{path}
        """
    end
  end

  defp stdio_entry(name, config) do
    {metadata, transport_config} = extract_upstream_metadata(config)

    %{
      name: name,
      impl: PtcRunnerMcp.Upstream.Stdio,
      config: normalize_stdio_config_with_env_resolution(transport_config),
      metadata: metadata
    }
  end

  # ----------------------------------------------------------------
  # Phase 2E: HTTP upstream parsing (§5.3, §5.5)
  # ----------------------------------------------------------------

  # RFC 7230 token grammar — used for both `static_headers:` keys and
  # `custom_header` emitter `header:` fields.
  @rfc7230_token_regex ~r/^[A-Za-z0-9!#$%&'*+\-.^_`|~]+$/

  # Case-insensitive denylist for `static_headers:` (per §5.3.2). Stored
  # lowercase; checks lowercase the input before lookup.
  #
  # Two categories:
  #   * Auth-sensitive (must go through the `auth:` block):
  #     `authorization`, `proxy-authorization`, `cookie`, `set-cookie`,
  #     `x-api-key`.
  #   * Protocol-controlled (impl owns these per §6.1.1 / §6.3 — a
  #     static config value would override the negotiated value):
  #     `mcp-protocol-version`, `mcp-session-id`, `user-agent`.
  @static_headers_denylist ~w(
    authorization proxy-authorization cookie set-cookie x-api-key
    mcp-protocol-version mcp-session-id user-agent
  )

  # `auth:` custom_header emitter denylist (case-insensitive, per
  # §5.3.1). NARROWER than `@static_headers_denylist`:
  #
  #   * `Authorization` and `Proxy-Authorization` — use scheme
  #     "bearer" or "basic" instead. Spec §5.3.1 verbatim.
  #   * Protocol-controlled (impl owns per §6.1.1 / §6.3) — static
  #     vs auth doesn't matter; these must NEVER come from config:
  #     `mcp-protocol-version`, `mcp-session-id`, `user-agent`.
  #
  # Critically: `x-api-key`, `cookie`, `set-cookie` are NOT on this
  # list. `x-api-key` is the canonical use case for custom_header
  # secret-bearing headers (cited in §5.3.1's example shape). Cookies
  # via custom_header are unusual but not forbidden by the spec.
  @auth_custom_header_denylist ~w(
    authorization proxy-authorization
    mcp-protocol-version mcp-session-id user-agent
  )

  # HTTP defaults from §5.3.
  @http_default_handshake_timeout_ms 10_000
  @http_default_request_timeout_ms 30_000
  @http_default_max_response_bytes 2_097_152
  @http_default_connect_timeout_ms 5_000
  @http_default_pool_size 4
  @http_default_backoff_initial_ms 100
  @http_default_backoff_max_ms 30_000

  @doc false
  @spec parse_http_upstream(String.t(), map(), String.t()) :: %{
          name: String.t(),
          impl: module(),
          config: map(),
          metadata: map()
        }
  def parse_http_upstream(name, config, path) when is_map(config) do
    {metadata, config} = extract_upstream_metadata(config)

    allow_insecure_http = bool_field!(config, "allow_insecure_http", false, name, path)
    allow_insecure_auth = bool_field!(config, "allow_insecure_auth", false, name, path)

    url = http_url!(name, config, allow_insecure_http, path)
    static_headers = http_static_headers!(name, config, path)
    proxy = http_proxy!(name, config, path)

    handshake_timeout_ms =
      pos_int_field!(
        config,
        "handshake_timeout_ms",
        @http_default_handshake_timeout_ms,
        name,
        path
      )

    request_timeout_ms =
      pos_int_field!(config, "request_timeout_ms", @http_default_request_timeout_ms, name, path)

    max_response_bytes =
      pos_int_field!(config, "max_response_bytes", @http_default_max_response_bytes, name, path)

    connect_timeout_ms =
      pos_int_field!(config, "connect_timeout_ms", @http_default_connect_timeout_ms, name, path)

    pool_size = pos_int_field!(config, "pool_size", @http_default_pool_size, name, path)

    backoff_initial_ms =
      pos_int_field!(config, "backoff_initial_ms", @http_default_backoff_initial_ms, name, path)

    backoff_max_ms =
      pos_int_field!(config, "backoff_max_ms", @http_default_backoff_max_ms, name, path)

    # Phase 3B: parse `auth:` into a list of emitter maps (atom-keyed,
    # atom scheme). The Phase 1 cross-reference validator
    # (`validate_auth_binding_refs!/3`) runs BEFORE this function on the
    # raw string-keyed input — it has already verified that every
    # `binding:` reference exists in `credentials:` and that the
    # scheme/scheme_hint pair is compatible. This parser handles the
    # *shape* checks (whitelist, header grammar, denylist, duplicate
    # rejection) per §5.3.1 / §5.5 ##7, 8.
    auth = parse_auth_emitters!(name, Map.get(config, "auth"), path)

    # §5.3.2 final bullet: header names emitted by `auth:` MUST NOT
    # collide with `static_headers:` names (case-insensitive). The
    # static_headers denylist already rejects `Authorization`; this
    # check catches `custom_header`-vs-`static_headers` collisions on
    # arbitrary names like `X-Foo`.
    :ok = check_auth_static_collision!(name, auth, static_headers, path)

    # §3 / §5.5 #2: insecure-auth gate. `allow_insecure_http: true` plus
    # any auth emitters requires the operator to ALSO set
    # `allow_insecure_auth: true` — two explicit opt-ins. Empty `auth:
    # []` (after parsing) does NOT trigger the gate, matching Phase 2
    # behavior.
    :ok =
      check_insecure_auth_gate!(name, allow_insecure_http, allow_insecure_auth, auth, path)

    out_config = %{
      url: url,
      static_headers: static_headers,
      proxy: proxy,
      handshake_timeout_ms: handshake_timeout_ms,
      request_timeout_ms: request_timeout_ms,
      connect_timeout_ms: connect_timeout_ms,
      max_response_bytes: max_response_bytes,
      pool_size: pool_size,
      backoff_initial_ms: backoff_initial_ms,
      backoff_max_ms: backoff_max_ms,
      auth: auth
    }

    %{
      name: name,
      impl: PtcRunnerMcp.Upstream.Http,
      config: out_config,
      metadata: metadata
    }
  end

  defp http_url!(name, config, allow_insecure_http, path) do
    raw = Map.get(config, "url")

    if not is_binary(raw) or raw == "" do
      raise """
      upstreams_config: upstream '#{name}' is transport: "http" but `url:` is missing or empty.

      Source: #{path}
      """
    else
      case URI.new(raw) do
        {:ok, %URI{scheme: scheme, host: host}}
        when is_binary(scheme) and is_binary(host) and host != "" ->
          validate_url_scheme!(name, raw, scheme, allow_insecure_http, path)
          raw

        _ ->
          raise """
          upstreams_config: upstream '#{name}' has malformed `url:` value: #{inspect(raw)}.

          URL must parse cleanly via URI.new/1 and have a host.

          Source: #{path}
          """
      end
    end
  end

  defp validate_url_scheme!(_name, _raw, "https", _allow_insecure_http, _path), do: :ok

  defp validate_url_scheme!(_name, _raw, "http", true, _path), do: :ok

  defp validate_url_scheme!(name, raw, "http", false, path) do
    raise """
    upstreams_config: upstream '#{name}' uses http:// URL '#{raw}' without `allow_insecure_http: true`.

    Plaintext HTTP requires an explicit opt-in. Set `"allow_insecure_http": true`
    on this upstream entry, or switch the URL to https://.

    Source: #{path}
    """
  end

  defp validate_url_scheme!(name, raw, scheme, _allow_insecure_http, path) do
    raise """
    upstreams_config: upstream '#{name}' has unsupported URL scheme '#{scheme}://' \
    in '#{raw}'.

    Only http:// and https:// are supported.

    Source: #{path}
    """
  end

  defp http_static_headers!(_name, %{"static_headers" => nil}, _path), do: []

  defp http_static_headers!(name, %{"static_headers" => headers}, path) when is_map(headers) do
    headers
    |> Enum.reduce({[], MapSet.new()}, fn {key, value}, {acc, seen} ->
      validate_static_header!(name, key, value, path)

      lower = String.downcase(key)

      if MapSet.member?(seen, lower) do
        raise """
        upstreams_config: upstream '#{name}' has duplicate static header '#{lower}' \
        (after case-folding).

        HTTP allows duplicate header names but Streamable HTTP servers treat them
        inconsistently; rejecting at config-load is unambiguous.

        Source: #{path}
        """
      end

      {[{lower, value} | acc], MapSet.put(seen, lower)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp http_static_headers!(name, %{"static_headers" => other}, path) do
    raise """
    upstreams_config: upstream '#{name}' `static_headers:` must be an object, got: \
    #{inspect(other)}.

    Source: #{path}
    """
  end

  defp http_static_headers!(_name, _config, _path), do: []

  defp validate_static_header!(name, key, value, path) do
    cond do
      not is_binary(key) ->
        raise """
        upstreams_config: upstream '#{name}' static_headers: header name must be a string, \
        got: #{inspect(key)}.

        Source: #{path}
        """

      not Regex.match?(@rfc7230_token_regex, key) ->
        raise """
        upstreams_config: upstream '#{name}' static_headers: header name '#{key}' violates \
        RFC 7230 token grammar.

        Allowed characters: A-Z a-z 0-9 ! # $ % & ' * + - . ^ _ ` | ~

        Source: #{path}
        """

      String.downcase(key) in @static_headers_denylist ->
        raise """
        upstreams_config: upstream '#{name}' static_headers: header name '#{key}' is in \
        the sensitive-name denylist (case-insensitive).

        Use the `auth:` block for `Authorization`-class headers; static_headers is for
        non-secret headers only.

        Source: #{path}
        """

      not is_binary(value) ->
        raise """
        upstreams_config: upstream '#{name}' static_headers['#{key}']: value must be a string, \
        got: #{inspect(value)}.

        Source: #{path}
        """

      true ->
        :ok
    end
  end

  defp http_proxy!(_name, %{"proxy" => nil}, _path), do: nil

  defp http_proxy!(name, %{"proxy" => proxy}, path) when is_binary(proxy) do
    case URI.new(proxy) do
      {:ok, %URI{scheme: scheme, host: host, port: port, userinfo: userinfo}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and is_integer(port) ->
        if userinfo not in [nil, ""] do
          raise """
          upstreams_config: upstream '#{name}' proxy URL '#{proxy}' contains user:pass@ \
          syntax.

          v1 does not support proxy auth (per §5.3.3). Configure proxy auth via OS-level
          mechanisms (e.g., a local unauthenticated SOCKS proxy) and point `proxy:` at
          the unauthenticated endpoint.

          Source: #{path}
          """
        end

        proxy

      _ ->
        raise """
        upstreams_config: upstream '#{name}' has malformed `proxy:` value: #{inspect(proxy)}.

        Proxy must be of the form http://host:port or https://host:port.

        Source: #{path}
        """
    end
  end

  defp http_proxy!(name, %{"proxy" => other}, path) do
    raise """
    upstreams_config: upstream '#{name}' `proxy:` must be a string or null, got: \
    #{inspect(other)}.

    Source: #{path}
    """
  end

  defp http_proxy!(_name, _config, _path), do: nil

  defp pos_int_field!(config, key, default, name, path) do
    case Map.fetch(config, key) do
      :error ->
        default

      {:ok, n} when is_integer(n) and n > 0 ->
        n

      {:ok, other} ->
        raise """
        upstreams_config: upstream '#{name}' field '#{key}' must be a positive integer, got: \
        #{inspect(other)}.

        Source: #{path}
        """
    end
  end

  defp bool_field!(config, key, default, name, path) do
    case Map.fetch(config, key) do
      :error ->
        default

      {:ok, v} when is_boolean(v) ->
        v

      {:ok, other} ->
        raise """
        upstreams_config: upstream '#{name}' field '#{key}' must be a boolean, got: \
        #{inspect(other)}.

        Source: #{path}
        """
    end
  end

  # §3 non-goal "two explicit opt-ins": when the URL is plaintext AND
  # the entry carries auth emitters, the operator must opt in twice.
  # Empty / absent / null `auth:` and HTTPS URLs both bypass this check.
  # `auth` here is the post-parse emitter list (atom-keyed maps); empty
  # list bypasses the gate, same as Phase 2's empty/null behavior.
  defp check_insecure_auth_gate!(name, true, false, auth, path)
       when is_list(auth) and auth != [] do
    raise """
    upstreams_config: upstream '#{name}' has `allow_insecure_http: true` and a non-empty \
    `auth:` list, but `allow_insecure_auth:` is not set.

    Sending credentials over plaintext HTTP requires TWO explicit opt-ins (§3): set
    `"allow_insecure_auth": true` on the upstream entry to confirm. Production deployments
    should use https:// and remove both flags.

    Source: #{path}
    """
  end

  defp check_insecure_auth_gate!(_name, _allow_insecure_http, _allow_insecure_auth, _auth, _path),
    do: :ok

  # ----------------------------------------------------------------
  # Phase 3B: `auth:` emitter list parser (§5.3.1, §5.5 ##7, 8)
  # ----------------------------------------------------------------

  # Whitelist of recognized scheme strings → atom. Using a fixed map
  # avoids `String.to_atom/1` on user input (CLAUDE.md guideline).
  @auth_schemes %{
    "bearer" => :bearer,
    "basic" => :basic,
    "custom_header" => :custom_header
  }

  # Recognized emitter-map keys. Anything else triggers a loud error so
  # typos like `"sceme"` fail at config-load instead of silently
  # producing a no-op emitter.
  @auth_emitter_keys ~w(scheme binding header)

  # Parse the optional `auth:` value on an HTTP upstream entry. Returns
  # a (possibly empty) list of atom-keyed emitter maps in input order.
  # Absent / nil / empty list all collapse to `[]` so downstream code
  # never has to special-case the "no auth" path.
  #
  # On any shape error (unknown scheme, missing required field,
  # forbidden header name, duplicate header within the list, ...) this
  # raises a `RuntimeError` with the upstream name, the offending
  # value, and the source path.
  @spec parse_auth_emitters!(String.t(), term(), String.t()) ::
          [
            %{
              scheme: :bearer | :basic | :custom_header,
              binding: String.t(),
              header: String.t() | nil
            }
          ]
  defp parse_auth_emitters!(_name, nil, _path), do: []
  defp parse_auth_emitters!(_name, [], _path), do: []

  defp parse_auth_emitters!(name, list, path) when is_list(list) do
    parsed = Enum.map(list, fn entry -> parse_auth_emitter!(name, entry, path) end)
    :ok = reject_duplicate_emitter_headers!(name, parsed, path)
    parsed
  end

  defp parse_auth_emitters!(name, other, path) do
    raise """
    upstreams_config: upstream '#{name}' `auth:` must be a list of emitter \
    objects, got: #{inspect(other)}.

    Source: #{path}
    """
  end

  # Single emitter parser. Raises on any shape problem — see callers
  # for the exhaustive list of rules.
  defp parse_auth_emitter!(name, entry, path) when is_map(entry) do
    :ok = reject_unknown_emitter_keys!(name, entry, path)

    scheme = parse_emitter_scheme!(name, entry, path)
    binding = parse_emitter_binding!(name, entry, path)
    header = parse_emitter_header!(name, scheme, entry, path)

    %{scheme: scheme, binding: binding, header: header}
  end

  defp parse_auth_emitter!(name, other, path) do
    raise """
    upstreams_config: upstream '#{name}' auth: emitter must be an object, got: \
    #{inspect(other)}.

    Source: #{path}
    """
  end

  defp reject_unknown_emitter_keys!(name, entry, path) do
    unknown =
      entry
      |> Map.keys()
      |> Enum.reject(&(&1 in @auth_emitter_keys))

    if unknown != [] do
      raise """
      upstreams_config: upstream '#{name}' auth: emitter has unknown key(s): \
      #{inspect(unknown)}.

      Recognized keys: #{inspect(@auth_emitter_keys)}.

      Source: #{path}
      """
    end

    :ok
  end

  defp parse_emitter_scheme!(name, entry, path) do
    case Map.fetch(entry, "scheme") do
      :error ->
        raise """
        upstreams_config: upstream '#{name}' auth: emitter is missing required \
        `scheme:` field.

        Recognized schemes: "bearer", "basic", "custom_header".

        Source: #{path}
        """

      {:ok, value} ->
        case Map.fetch(@auth_schemes, value) do
          {:ok, atom} ->
            atom

          :error ->
            raise """
            upstreams_config: upstream '#{name}' auth: emitter has unknown \
            scheme #{inspect(value)}.

            Recognized schemes: "bearer", "basic", "custom_header".

            Source: #{path}
            """
        end
    end
  end

  defp parse_emitter_binding!(name, entry, path) do
    case Map.fetch(entry, "binding") do
      {:ok, b} when is_binary(b) and b != "" ->
        b

      _ ->
        raise """
        upstreams_config: upstream '#{name}' auth: emitter is missing required \
        non-empty string `binding:` field.

        Source: #{path}
        """
    end
  end

  # `:bearer` and `:basic` schemes MUST NOT carry a `header:` field
  # (operators who set one are confused about which scheme they want —
  # loud error). `:custom_header` REQUIRES a `header:` field that
  # passes RFC 7230 grammar, is not `Authorization` (use bearer/basic
  # instead), and is not in the static_headers denylist (those are all
  # protocol-controlled or auth-class names). Whitespace in the header
  # is **not** trimmed — RFC 7230 forbids whitespace in tokens, so a
  # leading/trailing space simply fails the grammar check loudly.
  defp parse_emitter_header!(name, scheme, entry, path) when scheme in [:bearer, :basic] do
    case Map.fetch(entry, "header") do
      :error ->
        nil

      {:ok, nil} ->
        nil

      {:ok, other} ->
        raise """
        upstreams_config: upstream '#{name}' auth: emitter scheme '#{scheme}' \
        must not carry a `header:` field (got: #{inspect(other)}).

        The `header:` field is only valid for scheme "custom_header".

        Source: #{path}
        """
    end
  end

  defp parse_emitter_header!(name, :custom_header, entry, path) do
    case Map.fetch(entry, "header") do
      {:ok, header} when is_binary(header) ->
        :ok = validate_custom_header_name!(name, header, path)
        header

      _ ->
        raise """
        upstreams_config: upstream '#{name}' auth: emitter scheme \
        'custom_header' is missing required string `header:` field.

        Source: #{path}
        """
    end
  end

  defp validate_custom_header_name!(name, header, path) do
    cond do
      not Regex.match?(@rfc7230_token_regex, header) ->
        raise """
        upstreams_config: upstream '#{name}' auth: custom_header `header:` \
        '#{header}' violates RFC 7230 token grammar.

        Allowed characters: A-Z a-z 0-9 ! # $ % & ' * + - . ^ _ ` | ~

        Source: #{path}
        """

      String.downcase(header) == "authorization" ->
        raise """
        upstreams_config: upstream '#{name}' auth: custom_header `header:` \
        cannot be 'Authorization' (case-insensitive).

        Use scheme "bearer" or "basic" to emit the Authorization header.

        Source: #{path}
        """

      String.downcase(header) in @auth_custom_header_denylist ->
        raise """
        upstreams_config: upstream '#{name}' auth: custom_header `header:` \
        '#{header}' is reserved (case-insensitive).

        Reserved names: Authorization / Proxy-Authorization (use scheme
        "bearer"/"basic"); MCP-Protocol-Version / Mcp-Session-Id /
        User-Agent (impl-controlled per §6.1.1 / §6.3).

        Other static_headers-denylisted names like X-Api-Key / Cookie
        are valid custom_header use cases and ARE permitted here.

        Source: #{path}
        """

      true ->
        :ok
    end
  end

  # §5.3.1: reject duplicate header names produced by emitters within a
  # single upstream's `auth:` list (case-insensitive). Two `bearer`
  # emitters both produce `Authorization`; a `bearer` + a `basic` does
  # the same; two `custom_header` emitters with the same `header:` (any
  # case) collide. The error message names the duplicated header so
  # operators can find it quickly.
  defp reject_duplicate_emitter_headers!(name, parsed, path) do
    _final =
      parsed
      |> Enum.map(&emitter_header_name/1)
      |> Enum.reduce(MapSet.new(), fn header, seen ->
        if MapSet.member?(seen, header) do
          raise """
          upstreams_config: upstream '#{name}' has duplicate `auth:` emitter \
          header '#{header}' (case-insensitive).

          Multiple emitters cannot produce the same HTTP header — pick one.

          Source: #{path}
          """
        end

        MapSet.put(seen, header)
      end)

    :ok
  end

  # The lowercased header name an emitter would produce at request
  # time. `:bearer` and `:basic` both emit `Authorization` (so a
  # bearer + basic pair collides). `:custom_header` emits its
  # case-folded `header:` field.
  defp emitter_header_name(%{scheme: :bearer}), do: "authorization"
  defp emitter_header_name(%{scheme: :basic}), do: "authorization"
  defp emitter_header_name(%{scheme: :custom_header, header: header}), do: String.downcase(header)

  # §5.3.2 final bullet: header names emitted by `auth:` MUST NOT
  # collide with `static_headers:` keys (case-insensitive). The static
  # headers list is already lowercased by `http_static_headers!/3`.
  defp check_auth_static_collision!(name, auth, static_headers, path) do
    static_names = MapSet.new(static_headers, fn {key, _value} -> key end)

    Enum.each(auth, fn emitter ->
      header = emitter_header_name(emitter)

      if MapSet.member?(static_names, header) do
        raise """
        upstreams_config: upstream '#{name}' header '#{header}' is emitted by \
        both `auth:` and `static_headers:` (case-insensitive).

        Each header name must come from exactly one source — remove the
        `static_headers:` entry, or remove the `auth:` emitter.

        Source: #{path}
        """
      end
    end)

    :ok
  end

  # Parse the optional top-level `credentials:` block.
  # Raises with a clear message on shape errors per §5.5 #1 / #11.
  @spec parse_credentials_block!(map(), String.t()) ::
          %{String.t() => Credentials.Binding.t()}
  defp parse_credentials_block!(decoded, path) do
    raw = Map.get(decoded, "credentials")

    case Credentials.Binding.parse_block(raw) do
      {:ok, bindings} ->
        # Use the same release-safe Mix.env() check as `in_test?/0`
        # below — `:mix` is not part of the release applications, so
        # an unguarded `Mix.env()` crashes a production release on
        # config load. See codex-review of 43640bd [P1] #3.
        env = if in_test?(), do: :test, else: :prod
        warn_about_literal_bindings(bindings, path, env)
        bindings

      {:error, reason, detail} ->
        raise """
        upstreams_config: credentials: block is invalid (#{reason}).

        #{detail}

        Source: #{path}
        """
    end
  end

  # §5.4.1 / §5.5 #4: literal bindings outside MIX_ENV: :test emit a
  # Logger.warning at config-load time. Shipping a literal secret in a
  # config file is a known footgun. Suppressed in :test because tests
  # use literals heavily for fixture purposes. Warning includes the
  # binding name but never the value. `env` is passed explicitly so
  # tests can exercise both branches.
  @doc false
  @spec warn_about_literal_bindings(
          %{String.t() => Credentials.Binding.t()},
          String.t(),
          atom()
        ) :: :ok
  def warn_about_literal_bindings(bindings, path, env)
      when is_map(bindings) do
    if env != :test do
      for {name, %Credentials.Binding{source: :literal}} <- bindings do
        Log.log(:warn, "credentials_literal_binding", %{
          binding: name,
          source: path,
          hint: "literal bindings ship the secret in the config file; prefer env or file source"
        })
      end
    end

    :ok
  end

  # §5.5 #1 cross-reference validator. For each upstream entry's
  # `auth:` list, every emitter's `binding:` MUST appear in the
  # parsed `credentials:` block. Stdio configs in Phase 1 carry no
  # `auth:` block (HTTP-only field), so this is a no-op for v1
  # configs — but the hook is in place so Phase 3 / future HTTP
  # entries fail loudly at config-load.
  @doc false
  @spec validate_auth_binding_refs!(
          %{String.t() => map()},
          %{String.t() => Credentials.Binding.t()},
          String.t()
        ) :: :ok
  def validate_auth_binding_refs!(upstreams, bindings, source_path)
      when is_map(upstreams) and is_map(bindings) do
    for {name, entry} <- upstreams,
        is_map(entry),
        auth_list = Map.get(entry, "auth"),
        is_list(auth_list),
        emitter <- auth_list,
        is_map(emitter),
        binding_ref = Map.get(emitter, "binding"),
        is_binary(binding_ref) do
      case Map.fetch(bindings, binding_ref) do
        :error ->
          raise """
          upstreams_config: upstream '#{name}' references unknown credentials \
          binding '#{binding_ref}'.

          Define this binding under the top-level `credentials:` block, or
          remove the auth emitter that references it.

          Known bindings: #{inspect(Map.keys(bindings))}
          Source: #{source_path}
          """

        {:ok, %Credentials.Binding{} = binding} ->
          check_scheme_hint_compat!(name, emitter, binding, source_path)
      end
    end

    :ok
  end

  # §4.5 dep-presence check. If any upstream entry declares
  # `transport: "http"` (a raw string at this point — full HTTP config
  # parsing lands in Phase 2E), `:req` MUST be loaded. The check uses
  # `Code.ensure_loaded?/1` so that an absent `:req` (Mix dep marked
  # `optional: true`) does not crash compile-time module references.
  #
  # `loaded?` is injected so the test suite can simulate `:req` being
  # absent without unloading the application — defaults to a real
  # `Code.ensure_loaded?/1` probe.
  @doc false
  @spec check_http_deps!(%{String.t() => map()}, String.t()) :: :ok
  def check_http_deps!(upstreams, source_path)
      when is_map(upstreams) and is_binary(source_path) do
    check_http_deps!(upstreams, source_path, &Code.ensure_loaded?/1)
  end

  @doc false
  @spec check_http_deps!(
          %{String.t() => map()},
          String.t(),
          (module() -> boolean())
        ) :: :ok
  def check_http_deps!(upstreams, source_path, loaded?)
      when is_map(upstreams) and is_binary(source_path) and is_function(loaded?, 1) do
    for {name, entry} <- upstreams,
        is_map(entry),
        Map.get(entry, "transport") == "http" do
      unless loaded?.(Req) do
        raise """
        upstreams_config: upstream '#{name}' uses HTTP transport but :req is not available.
        Add `{:req, "~> 0.5"}` to your deps in mix.exs and run `mix deps.get`.
        Source: #{source_path}
        """
      end
    end

    :ok
  end

  # §5.5 #7 first bullet: an emitter's `scheme` MUST be compatible
  # with the referenced binding's `scheme_hint`. `:bearer` only feeds
  # bearer emitters, `:basic` only feeds basic emitters, `:raw` (or
  # absent → :raw via Binding.parse defaults) feeds any. Mismatch is
  # a loud config-load error so operators catch "used the wrong
  # binding" mistakes before any HTTP request goes out (Phase 3).
  defp check_scheme_hint_compat!(upstream_name, emitter, binding, source_path) do
    scheme_str = Map.get(emitter, "scheme")
    hint = binding.scheme_hint || :raw

    cond do
      not is_binary(scheme_str) ->
        # The emitter has no scheme field, or it's not a string. Phase 1
        # only validates references; full emitter shape parsing lands in
        # Phase 3. Skip the compat check — the bad shape is Phase 3's
        # to reject.
        :ok

      hint == :raw ->
        # :raw bindings feed any scheme. No mismatch possible.
        :ok

      scheme_compatible_with_hint?(scheme_str, hint) ->
        :ok

      true ->
        raise """
        upstreams_config: upstream '#{upstream_name}' auth emitter '#{scheme_str}' \
        is incompatible with binding '#{binding.name}' (scheme_hint: #{hint}).

        A '#{hint}' binding can only feed a '#{hint}' emitter. Remove the
        scheme_hint from the binding (defaults to :raw, which feeds any
        scheme), or pick a binding whose scheme_hint matches.

        Source: #{source_path}
        """
    end
  end

  defp scheme_compatible_with_hint?("bearer", :bearer), do: true
  defp scheme_compatible_with_hint?("basic", :basic), do: true
  defp scheme_compatible_with_hint?("custom_header", :raw), do: true
  defp scheme_compatible_with_hint?(_scheme, _hint), do: false

  # §5.2 / §5.5 #6: the legacy `${VAR}` placeholder resolver applies
  # ONLY to stdio `env` map values. `credentials:` and (Phase 2's)
  # `static_headers:` / `url` / `auth` fields are parsed literally.
  # Narrowing keeps `${VAR}` from accidentally expanding inside future
  # HTTP config keys where the resulting plaintext would land in
  # logs / `inspect/1` of upstream config.
  @metadata_keys ["description", "capabilities"]

  defp extract_upstream_metadata(config) when is_map(config) do
    description = validate_metadata_description(Map.get(config, "description"))
    capabilities = validate_metadata_capabilities(Map.get(config, "capabilities"))

    metadata =
      %{}
      |> maybe_put(:description, description)
      |> maybe_put(:capabilities, capabilities)

    transport_config = Map.drop(config, @metadata_keys)
    {metadata, transport_config}
  end

  defp validate_metadata_description(nil), do: nil
  defp validate_metadata_description(value) when is_binary(value), do: value

  defp validate_metadata_description(value) do
    Log.log(:warn, "upstream_metadata_invalid", %{
      field: "description",
      reason: "expected string, got #{inspect(value)}"
    })

    nil
  end

  defp validate_metadata_capabilities(nil), do: nil
  defp validate_metadata_capabilities(value) when is_list(value), do: value

  defp validate_metadata_capabilities(value) do
    Log.log(:warn, "upstream_metadata_invalid", %{
      field: "capabilities",
      reason: "expected array, got #{inspect(value)}"
    })

    nil
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_stdio_config_with_env_resolution(config) when is_map(config) do
    config
    |> resolve_stdio_env_placeholders()
    |> normalize_stdio_config()
  end

  # Resolve `${VAR}` only inside the `env` sub-map of a stdio upstream
  # entry. Nothing else in the config is touched. Pre-narrowing the
  # resolver was recursive over the whole entry which would, in Phase
  # 2, expand `${VAR}` inside `static_headers:` and `url` — exactly
  # the leak path the credentials registry exists to close (§5.3,
  # §14.2).
  defp resolve_stdio_env_placeholders(config) when is_map(config) do
    case Map.fetch(config, "env") do
      {:ok, env_map} when is_map(env_map) ->
        Map.put(config, "env", Map.new(env_map, fn {k, v} -> {k, expand_placeholder(v)} end))

      _ ->
        config
    end
  end

  defp expand_placeholder(value) when is_binary(value) do
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

  defp expand_placeholder(value), do: value

  # Convert a string-keyed map (Jason output) to the atom-keyed
  # shape `Upstream.Stdio` (and the owning `Upstream.Connection`)
  # expects. Whitelisted keys only — anything not recognized is
  # dropped on the floor with a warning, so a typo in the JSON file
  # (e.g. `"command_": "..."`) is loud rather than silently
  # launching the wrong subprocess.
  #
  # The whitelist is the union of every config key consumed by an
  # upstream-config reader. Codex review of `0f6c1cd` flagged that
  # `:handshake_timeout_ms` was missing — slow-handshake upstreams
  # that explicitly bumped the timeout had it silently dropped.
  # The full audit:
  #
  #   * `Upstream.Stdio` reads: :command, :args, :env, :cd,
  #     :handshake_timeout_ms.
  #   * `Upstream.Connection` (which owns the upstream impl)
  #     reads: :backoff_initial_ms, :backoff_max_ms.
  #
  # NOTE: `:env` values stay string-keyed maps. Env-var names are
  # external strings, not internal atoms; converting them with
  # `String.to_atom/1` would also be a memory leak per CLAUDE.md.
  @stdio_config_keys ~w(command args env cd handshake_timeout_ms backoff_initial_ms backoff_max_ms)
  @stdio_config_atoms %{
    "command" => :command,
    "args" => :args,
    "env" => :env,
    "cd" => :cd,
    "handshake_timeout_ms" => :handshake_timeout_ms,
    "backoff_initial_ms" => :backoff_initial_ms,
    "backoff_max_ms" => :backoff_max_ms
  }

  @doc false
  @spec normalize_stdio_config(map()) :: map()
  def normalize_stdio_config(config) when is_map(config) do
    {known, unknown} =
      Enum.split_with(config, fn {k, _} -> k in @stdio_config_keys end)

    if unknown != [] do
      Log.log(:warn, "upstreams_config_unknown_keys", %{
        keys: Enum.map(unknown, fn {k, _} -> k end)
      })
    end

    Map.new(known, fn {k, v} -> {Map.fetch!(@stdio_config_atoms, k), v} end)
  end

  # §5.3 self-as-upstream rejection. The MCP server MUST refuse to
  # start when it is configured as an upstream of itself, by command
  # path match. This guard fires at config-load time so misconfigured
  # deploys fail loudly before the supervisor tree comes up.
  #
  # Heuristic ("command path match"): we resolve each entry's
  # `:command` to an absolute filesystem path (via `System.find_executable/1`
  # for bare names, `Path.expand/1` for paths). We then reject the
  # entry if EITHER:
  #
  #   1. The resolved absolute path equals the absolute path of the
  #      currently-running release executable (when one exists,
  #      detected via the `RELEASE_ROOT` env var that releases set).
  #   2. The basename of the resolved command equals the configured
  #      release name `ptc_runner_mcp` — catches a misconfigured
  #      copy of the same release executable installed elsewhere.
  #
  # Limit acknowledged in spec: "Multi-hop cycles across separate
  # PtcRunner processes are unsafeguarded." Programs that loop will
  # eventually hit `max_upstream_calls_per_program` or `program_timeout`.
  @release_basename "ptc_runner_mcp"

  @doc false
  @spec reject_self_as_upstream!([map()], String.t()) :: :ok
  def reject_self_as_upstream!(entries, source_path) when is_list(entries) do
    Enum.each(entries, fn %{name: name, config: config} ->
      command = Map.get(config, :command)

      if is_binary(command) and command != "" and self_command?(command) do
        raise """
        upstreams_config: self-as-upstream rejected (§5.3).

        Entry "#{name}" configures command "#{command}" which resolves
        to the currently-running PtcRunner release. Recursive
        self-spawn would either hang on the handshake or run away.

        Source: #{source_path}
        """
      end
    end)

    :ok
  end

  defp self_command?(command) do
    resolved = resolve_command_path(command)

    cond do
      is_nil(resolved) ->
        false

      Path.basename(resolved) == @release_basename ->
        true

      true ->
        case release_executable_path() do
          nil -> false
          path -> Path.expand(resolved) == Path.expand(path)
        end
    end
  end

  defp resolve_command_path(command) do
    if String.contains?(command, "/") do
      Path.expand(command)
    else
      System.find_executable(command)
    end
  end

  defp release_executable_path do
    case System.get_env("RELEASE_ROOT") do
      nil ->
        nil

      "" ->
        nil

      root ->
        Path.join([root, "bin", @release_basename])
    end
  end

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
