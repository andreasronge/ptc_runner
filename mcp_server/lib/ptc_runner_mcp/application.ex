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

  alias PtcRunnerMcp.Http.{Config, Server}
  alias PtcRunnerMcp.Http.SessionRegistry, as: HttpSessionRegistry
  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig

  @impl Application
  def start(_type, _args) do
    PtcRunner.Dotenv.load()
    args = parse_args(System.argv())

    Log.set_level(env_or(args, :log_level, "PTC_RUNNER_MCP_LOG_LEVEL", "info"))

    aggregator_config = load_aggregator_config(args)

    %{upstreams: upstreams, credentials: bindings, raw_envelope_policy: raw_envelope_policy} =
      aggregator_config

    apply_aggregator_config(args, raw_envelope_policy)
    apply_catalog_config(args)
    root_runtime_opts = root_runtime_opts(Map.get(aggregator_config, :root_runtime_opts))
    apply_agentic_config(args)
    apply_debug_config(args)
    apply_response_profile(args)
    apply_limits(args, aggregator?: root_runtime_opts != nil)
    apply_sessions_config(args)
    {:ok, http_config} = Config.resolve(args)
    Application.put_env(:ptc_runner_mcp, :http_config, http_config)
    validate_agentic_boot!([], root_runtime_opts != nil)
    apply_trace_config(args)

    if AgenticConfig.enabled?() and upstreams == [] and root_runtime_opts == nil do
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
      cond do
        http_config.enabled ->
          build_http_children(upstreams, bindings, http_config, root_runtime_opts)

        attach_stdio?() ->
          build_children(upstreams, bindings, args, root_runtime_opts)

        true ->
          []
      end

    # `:rest_for_one` per `Plans/http-transport-credentials.md` §7.1.
    # `Credentials` is the first child; if it crashes we want every
    # later child (HTTP upstream impls in Phase 2/3) restarted so
    # they re-handshake against the freshly-rebuilt redaction set.
    opts = [strategy: :rest_for_one, name: PtcRunnerMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl Application
  def prep_stop(state) do
    case Application.get_env(:ptc_runner_mcp, :http_config) do
      %{enabled: true, shutdown_grace_ms: grace_ms} ->
        if Process.whereis(HttpSessionRegistry) do
          _ = HttpSessionRegistry.begin_drain()
          Process.sleep(grace_ms)
          _ = HttpSessionRegistry.cancel_all(:shutdown)
        end

      _ ->
        :ok
    end

    state
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
  def build_children(_upstreams, bindings, args, root_runtime_opts \\ nil) do
    [{Credentials, [bindings: bindings]}] ++
      root_runtime_children(root_runtime_opts) ++
      session_children() ++
      stdio_children(args)
  end

  @doc false
  @spec build_http_children([map()], %{String.t() => Credentials.Binding.t()}, map()) ::
          [Supervisor.child_spec() | {module(), term()}]
  def build_http_children(_upstreams, bindings, http_config, root_runtime_opts \\ nil) do
    [{Credentials, [bindings: bindings]}] ++
      root_runtime_children(root_runtime_opts) ++
      session_children_for_http() ++
      [
        {HttpSessionRegistry, [config: http_config]},
        Server.child_spec(http_config)
      ] ++
      debug_children()
  end

  @doc false
  @spec build_repl_children([map()], %{String.t() => Credentials.Binding.t()}) ::
          [Supervisor.child_spec() | {module(), term()}]
  def build_repl_children(_upstreams, bindings, root_runtime_opts \\ nil) do
    [{Credentials, [bindings: bindings]}] ++
      root_runtime_children(root_runtime_opts) ++
      session_children() ++
      debug_children()
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
          response_profile: :string,
          http: :boolean,
          http_host: :string,
          http_port: :integer,
          http_path: :string,
          http_auth_token: :string,
          http_disable_auth: :boolean,
          http_allowed_origin: [:string, :keep],
          http_request_timeout_ms: :integer,
          http_shutdown_grace_ms: :integer,
          http_max_body_bytes: :integer,
          http_session_ttl_ms: :integer,
          http_session_idle_timeout_ms: :integer,
          http_max_sessions: :integer,
          http_max_sessions_per_owner: :integer,
          http_max_in_flight_per_session: :integer,
          http_allow_unsafe_network: :boolean,
          http_metrics: :boolean,
          http_metrics_path: :string,
          http_instance_label: :string
        ]
      )

    opts_to_map(opts)
  end

  defp opts_to_map(opts) do
    {origins, rest} = Keyword.pop_values(opts, :http_allowed_origin)

    rest
    |> Map.new()
    |> maybe_put_origins(origins)
  end

  defp maybe_put_origins(map, []), do: map
  defp maybe_put_origins(map, origins), do: Map.put(map, :http_allowed_origin, origins)

  # Public-but-undocumented seam used by tests to verify CLI > env >
  # default precedence for non-limit aggregator behavior.
  @doc false
  @spec apply_aggregator_config(map()) :: :ok
  def apply_aggregator_config(args, raw_envelope_policy \\ %{}) when is_map(args) do
    AggregatorConfig.set(%{
      read_only:
        read_bool(
          args,
          :aggregator_read_only,
          "PTC_RUNNER_MCP_AGGREGATOR_READ_ONLY",
          AggregatorConfig.defaults().read_only
        ),
      raw_envelope_default:
        Map.get(
          raw_envelope_policy,
          :raw_envelope_default,
          AggregatorConfig.defaults().raw_envelope_default
        ),
      upstreams: Map.get(raw_envelope_policy, :upstreams, %{})
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
  # default precedence for the opt-in `lisp_debug` tool config
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
  def validate_agentic_boot!(upstreams), do: validate_agentic_boot!(upstreams, false)

  @doc false
  @spec validate_agentic_boot!([map()], boolean()) :: :ok
  def validate_agentic_boot!(upstreams, root_runtime?) when is_list(upstreams) do
    cfg = AgenticConfig.get()
    upstream_configured? = upstreams != [] or root_runtime?

    cond do
      cfg.allow_writes and not cfg.enabled ->
        raise """
        agentic configuration invalid: --agentic-allow-writes requires --agentic.
        """

      cfg.enabled and upstream_configured? and not AggregatorConfig.read_only?() and
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
  # The `lisp_debug` ring buffer (`DebugBuffer`) is supervised here too,
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

  defp session_children_for_http do
    Sessions.child_specs()
  end

  defp root_runtime_children(nil), do: []

  defp root_runtime_children(opts) when is_list(opts) do
    opts = root_runtime_opts(opts)

    [
      {PtcRunner.Upstream.Runtime,
       opts
       |> Keyword.put(:name, PtcRunnerMcp.RootUpstreamRuntime.name())
       |> Keyword.put(
         :redaction_sink,
         {PtcRunnerMcp.RootUpstreamRuntime, :register_redaction_secrets, []}
       )}
    ]
  end

  defp root_runtime_opts(nil), do: nil

  defp root_runtime_opts(opts) when is_list(opts) do
    catalog = CatalogConfig.get()

    opts
    |> Keyword.put(:catalog_exposure_mode, catalog.catalog_mode)
    |> Keyword.put(:catalog_inline_max_chars, catalog.catalog_inline_max_chars)
    |> Keyword.put(:catalog_inline_max_tools, catalog.catalog_inline_max_tools)
  end

  # Root-owned upstream runtime configs are no longer expanded into MCP-owned
  # upstream entries. This helper is retained for older MCP-local boot plumbing
  # and always returns the already-parsed local child entries, currently `[]`.
  @doc false
  @spec load_upstreams_config(map()) :: []
  def load_upstreams_config(args) do
    load_aggregator_config(args).upstreams
  end

  # MCP aggregator loader now delegates upstream config parsing and validation to
  # `PtcRunner.Upstream.Runtime`. The returned MCP-local `upstreams` and
  # `credentials` entries stay empty; root runtime boot receives `config_path`
  # through `:root_runtime_opts`.
  @doc false
  @spec load_aggregator_config(map()) :: %{
          optional(:root_runtime_opts) => keyword(),
          upstreams: [],
          credentials: %{},
          raw_envelope_policy: map()
        }
  def load_aggregator_config(args) do
    path =
      env_or(args, :upstreams_config, "PTC_RUNNER_MCP_UPSTREAMS", nil) ||
        xdg_default_path()

    case path do
      nil ->
        %{upstreams: [], credentials: %{}, raw_envelope_policy: %{}}

      path when is_binary(path) ->
        case File.read(path) do
          {:ok, body} ->
            parse_aggregator_body(body, path)

          {:error, :enoent} ->
            %{upstreams: [], credentials: %{}, raw_envelope_policy: %{}}

          {:error, reason} ->
            Log.log(:warn, "upstreams_config_read_failed", %{
              path: path,
              reason: to_string(:file.format_error(reason))
            })

            %{upstreams: [], credentials: %{}, raw_envelope_policy: %{}}
        end
    end
  end

  defp parse_aggregator_body("", _path),
    do: %{upstreams: [], credentials: %{}, raw_envelope_policy: %{}}

  defp parse_aggregator_body(body, path) do
    case Jason.decode(body) do
      {:ok, %{"upstreams" => map} = decoded} when is_map(map) ->
        %{
          upstreams: [],
          credentials: %{},
          raw_envelope_policy: parse_raw_envelope_policy(decoded),
          root_runtime_opts: [
            config_path: path,
            catalog_exposure_mode: :auto,
            catalog_snapshot_mode: :frozen
          ]
        }

      {:ok, _other} ->
        Log.log(:warn, "upstreams_config_invalid", %{
          path: path,
          reason: "missing top-level :upstreams key"
        })

        %{upstreams: [], credentials: %{}, raw_envelope_policy: %{}}

      {:error, reason} ->
        Log.log(:warn, "upstreams_config_invalid", %{
          path: path,
          reason: inspect(reason, limit: 50)
        })

        %{upstreams: [], credentials: %{}, raw_envelope_policy: %{}}
    end
  end

  defp parse_raw_envelope_policy(decoded) when is_map(decoded) do
    %{
      raw_envelope_default: Map.get(decoded, "raw_envelope") == true,
      upstreams:
        decoded
        |> Map.get("upstreams", %{})
        |> Enum.into(%{}, fn {name, config} ->
          {name, parse_raw_envelope_upstream(config)}
        end)
    }
  end

  defp parse_raw_envelope_upstream(config) when is_map(config) do
    %{
      raw_envelope: raw_envelope_value(config),
      tools:
        config
        |> Map.get("tools", %{})
        |> Enum.into(%{}, fn {tool, tool_config} ->
          {tool, %{raw_envelope: raw_envelope_value(tool_config)}}
        end)
    }
  end

  defp parse_raw_envelope_upstream(_), do: %{raw_envelope: nil, tools: %{}}

  defp raw_envelope_value(%{"raw_envelope" => value}) when is_boolean(value), do: value
  defp raw_envelope_value(_), do: nil

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
