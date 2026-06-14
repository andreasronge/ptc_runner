defmodule PtcRunnerMcp.Tools do
  @moduledoc """
  `tools/list` and `tools/call` handlers.

  Per `Plans/ptc-runner-mcp-server.md` § 8.1, the server advertises
  exactly one tool, `lisp_eval`. The advertised description is
  composed by `PtcRunnerMcp.PromptRegistry` from MCP-owned prompt cards.

  Phase 2 wired real `Lisp.run/2` execution through
  `PtcRunnerMcp.Sandbox` and enforced `:max_program_bytes` and
  `:max_concurrent_calls` (§ 11). Phase 3 wires the remaining
  arguments:

    * `context` — JSON object whose keys land as `data/<key>` bindings
      inside the program. Validated for shape, key syntax, and
      encoded byte size before a concurrency permit is acquired.
    * `output_schema` — JSON Schema object converted to the internal
      return validator. Schema failure is `args_error`; mismatch
      between the schema and the program's return is `validation_error`.

  Both validations short-circuit before `ConcurrencyGate.try_acquire/1`
  so a malformed argument never consumes a permit.
  """

  alias PtcRunner.SubAgent.Signature
  alias PtcRunner.Upstream.{Eval, Result, RunContext}

  alias PtcRunnerMcp.{
    Agentic,
    AgenticConfig,
    CatalogConfig,
    ConcurrencyGate,
    DebugConfig,
    Envelope,
    Limits,
    OutputLimits,
    PayloadMetrics,
    PromptRegistry,
    ResponseProfile,
    RootUpstreamRuntime,
    Sandbox,
    Sessions,
    UpstreamResultFeedback
  }

  alias PtcRunnerMcp.AggregatorConfig
  alias PtcRunnerMcp.CatalogDescription

  @tool_name "lisp_eval"

  # § 10.4 outputSchema. `oneOf` discriminated by `status`.
  # `result` is intentionally NOT in the success branch's `required`
  # list — `render_success/2` elides it for programs whose final
  # expression and `lisp_step.return` are both nil (§ 7.4 D2).
  # `memory` was removed in issue #879: each MCP call is one-shot, so
  # surfacing memory.changed/stored_keys misled LLMs into thinking
  # state would persist. The renderer now omits the field entirely
  # for one-shot callers (`render_success_from_step/2`).
  @output_schema %{
    "type" => "object",
    "oneOf" => [
      %{
        "type" => "object",
        "required" => ["status", "prints", "feedback", "truncated"],
        "properties" => %{
          "status" => %{"const" => "ok"},
          "result" => %{"type" => "string"},
          "prints" => %{"type" => "array", "items" => %{"type" => "string"}},
          "feedback" => %{"type" => "string"},
          "truncated" => %{"type" => "boolean"},
          "output_truncated" => %{"type" => "boolean"},
          "prints_truncated" => %{"type" => "boolean"},
          "feedback_truncated" => %{"type" => "boolean"},
          "validated" => %{},
          "validated_preview" => %{"type" => "string"},
          "validated_preview_truncated" => %{"type" => "boolean"},
          "validated_bytes" => %{"type" => "integer", "minimum" => 0}
        }
      },
      %{
        "type" => "object",
        "required" => ["status", "reason", "message", "feedback"],
        "properties" => %{
          "status" => %{"const" => "error"},
          "reason" => %{
            "type" => "string",
            "enum" => [
              "parse_error",
              "runtime_error",
              "timeout",
              "memory_limit",
              "args_error",
              "fail",
              "validation_error",
              "busy",
              "cancelled",
              "unknown_tool",
              # MCP-only reason emitted by the drain path after `shutdown`.
              # Codex review of 0fe4c78: clients validating tool results
              # against the advertised schema would otherwise reject the
              # server's own shutdown-drain reply.
              "shutting_down"
            ]
          },
          "message" => %{"type" => "string"},
          "feedback" => %{"type" => "string"},
          "result" => %{"type" => "string"},
          "truncated" => %{"type" => "boolean"},
          "output_truncated" => %{"type" => "boolean"},
          "feedback_truncated" => %{"type" => "boolean"}
        }
      }
    ]
  }

  # Phase 1a §8.4: the aggregator-mode `outputSchema` extends the v1
  # schema with an optional `upstream_calls` array. Strict
  # `structuredContent` validators that don't know about the new
  # field would otherwise reject responses that include it.
  #
  # Phase 5 / `Plans/http-transport-credentials.md` §9.3 extends the
  # per-entry schema with two additional optional fields:
  #
  #   * `auth` — object `{scheme, binding}`, present when the upstream
  #     is HTTP and has at least one `auth:` emitter.
  #   * `http_status` — integer, present when a failure came from an
  #     HTTP response (4xx / 5xx / 429).
  #
  # Both are optional; stdio entries are byte-for-byte unchanged.
  # `Plans/ptc-runner-mcp-payload-reduction.md` §4.1 / §5: per-entry
  # `result_bytes` (`integer | null`) and `oversize` (`boolean`) — both
  # additive, both optional in the item schema (older entries lacked
  # them).
  @upstream_calls_schema %{
    "type" => "array",
    "items" => %{
      "type" => "object",
      "required" => ["server", "tool", "status", "duration_ms"],
      "properties" => %{
        "server" => %{"type" => "string"},
        "tool" => %{"type" => "string"},
        "status" => %{"type" => "string", "enum" => ["ok", "error"]},
        "duration_ms" => %{"type" => "integer", "minimum" => 0},
        "reason" => %{
          "type" => "string",
          "enum" => [
            "upstream_unavailable",
            "tool_error",
            "upstream_error",
            "auth_failed",
            "rate_limited",
            "timeout",
            "response_too_large",
            "cap_exhausted"
          ]
        },
        "error" => %{"type" => "string"},
        "result_bytes" => %{"type" => ["integer", "null"], "minimum" => 0},
        "oversize" => %{"type" => "boolean"},
        "auth" => %{
          "type" => "object",
          "required" => ["scheme", "binding"],
          "properties" => %{
            "scheme" => %{"type" => "string"},
            "binding" => %{"type" => "string"}
          }
        },
        "http_status" => %{"type" => "integer", "minimum" => 100, "maximum" => 599}
      }
    }
  }

  # `Plans/ptc-runner-mcp-payload-reduction.md` §5: the aggregator
  # schema also advertises an optional `ptc_metrics` object. A generic
  # `{"type": ["object", "null"]}` is sufficient — the block is pure
  # counts/ratios, never load-bearing for clients, and the discriminated
  # `oneOf` stays keyed on `status`.
  @ptc_metrics_schema %{"type" => ["object", "null"]}

  @aggregator_output_schema %{
    "type" => "object",
    "oneOf" =>
      Enum.map(@output_schema["oneOf"], fn branch ->
        Map.update!(branch, "properties", fn props ->
          props
          |> Map.put("upstream_calls", @upstream_calls_schema)
          |> Map.put("upstream_results", %{"type" => "array", "items" => %{"type" => "object"}})
          |> Map.put("ptc_metrics", @ptc_metrics_schema)
        end)
      end)
  }

  @compact_output_schema %{
    "type" => "object",
    "oneOf" => [
      %{
        "type" => "object",
        "required" => ["status"],
        "properties" => %{
          "status" => %{"const" => "ok"},
          "result" => %{"type" => "string"},
          "validated" => %{},
          "validated_preview" => %{"type" => "string"},
          "validated_preview_truncated" => %{"type" => "boolean"},
          "validated_bytes" => %{"type" => "integer", "minimum" => 0},
          "upstream_results" => %{"type" => "array", "items" => %{"type" => "object"}},
          "truncated" => %{"type" => "boolean"},
          "output_truncated" => %{"type" => "boolean"}
        }
      },
      %{
        "type" => "object",
        "required" => ["status", "reason", "message"],
        "properties" => %{
          "status" => %{"const" => "error"},
          "reason" => %{"type" => "string"},
          "message" => %{"type" => "string"},
          "feedback" => %{"type" => "string"},
          "result" => %{"type" => "string"},
          "truncated" => %{"type" => "boolean"},
          "output_truncated" => %{"type" => "boolean"},
          "feedback_truncated" => %{"type" => "boolean"},
          "upstream_calls" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "required" => ["server", "tool", "status"],
              "properties" => %{
                "server" => %{"type" => "string"},
                "tool" => %{"type" => "string"},
                "status" => %{"const" => "error"},
                "reason" => %{"type" => "string"}
              }
            }
          }
        }
      }
    ]
  }

  @doc """
  The rendered `lisp_eval` no-upstreams tool prompt.
  """
  @spec authoring_card() :: String.t()
  def authoring_card, do: PromptRegistry.render(:mcp_no_tools_description, [])

  @doc """
  The advertised `description` field for the `lisp_eval` tool,
  by capability profile.

  Phase 0 (`Plans/ptc-runner-mcp-aggregator.md` §11.1) refactors the
  former `advertised_description/0` into a profile-aware builder.
  The `opts` keyword is the seam aggregator mode will use to inject
  runtime catalog text in Phase 3 (`catalog: catalog_string_or_nil`).
  Phase 0 accepts and ignores `:catalog`; future profiles
  (`:mcp_aggregator`) consume it.
  """
  @spec advertised_description(profile :: atom(), opts :: keyword()) :: String.t()
  def advertised_description(profile, opts \\ [])

  def advertised_description(:mcp_no_tools, _opts) do
    PromptRegistry.render(:mcp_no_tools_description, [])
  end

  # Phase 1a §8.1: aggregator description = capability statement +
  # aggregator authoring card. The `:catalog` opt is the seam Phase 3
  # will use to inject an inline upstream catalog; for Phases 1a-2,
  # `catalog: nil` is acceptable per §8.1.
  def advertised_description(:mcp_aggregator, opts) do
    PromptRegistry.render(:mcp_aggregator_description, opts)
  end

  @doc """
  Profile-aware advertised description for the composed capability and
  response profile.
  """
  @spec advertised_description(atom(), ResponseProfile.t(), keyword()) :: String.t()
  def advertised_description(capability_profile, response_profile, opts)
      when response_profile in [:slim, :structured, :debug] do
    capability_profile
    |> advertised_description(opts)
    |> prepend_response_profile_note(capability_profile, response_profile)
  end

  @doc """
  The rendered `lisp_eval` with-upstreams tool prompt without a
  dynamic catalog.
  """
  @spec aggregator_authoring_card() :: String.t()
  def aggregator_authoring_card,
    do: PromptRegistry.render(:mcp_aggregator_description, catalog: nil)

  @doc """
  Backward-compatible alias for `advertised_description(:mcp_no_tools, [])`.

  Existing call sites (and test suites) use the 0-arity form; Phase 0
  preserves it as a thin wrapper so the v1 MCP profile reads
  identically before and after the §11.1 refactor.
  """
  @spec advertised_description() :: String.t()
  def advertised_description, do: advertised_description(:mcp_no_tools, catalog: nil)

  @doc """
  The advertised `outputSchema` for the `lisp_eval` tool, by
  capability profile.

  Phase 0 (`Plans/ptc-runner-mcp-aggregator.md` §11.4) makes the
  schema profile-selectable. For `:mcp_no_tools`, the schema is the
  v1 § 10.4 literal. The aggregator profile (Phase 1a) extends it
  with an optional `upstream_calls` array so strict
  `structuredContent` validators do not reject the new field.
  """
  @spec output_schema_for(profile :: atom()) :: map()
  def output_schema_for(:mcp_no_tools), do: @output_schema
  def output_schema_for(:mcp_aggregator), do: @aggregator_output_schema

  @doc """
  Advertised `outputSchema` for the composed capability and response
  profile. `nil` means no `outputSchema` should be advertised.
  """
  @spec output_schema_for(atom(), ResponseProfile.t()) :: map() | nil
  def output_schema_for(_capability_profile, :slim), do: nil
  def output_schema_for(_capability_profile, :structured), do: @compact_output_schema
  def output_schema_for(:mcp_no_tools, :debug), do: @output_schema
  def output_schema_for(:mcp_aggregator, :debug), do: @aggregator_output_schema

  @doc """
  Backward-compatible alias for `output_schema_for(:mcp_no_tools)`.

  Existing call sites and tests reference the 0-arity form; Phase 0
  routes it through the profile-aware builder so v1 output is
  unchanged byte-for-byte.
  """
  @spec output_schema() :: map()
  def output_schema, do: output_schema_for(:mcp_no_tools)

  @doc """
  Returns `true` iff the MCP server is operating in aggregator mode.

  Per `Plans/ptc-runner-mcp-aggregator.md` §4.1, this predicate is
  static and config-derived: aggregator mode is active when at least
  one upstream entry was loaded at startup. The predicate drives:

    * profile selection (description, annotations, `outputSchema`),
    * sandbox default limits (§9 / §11.6 aggregator overrides),
    * telemetry `profile:` metadata (`:mcp_aggregator` vs `:mcp_no_tools`).

  Crucially this is **not** the same as `Upstream.Registry.started_upstreams/0`
  — a misconfigured run with zero healthy upstreams still advertises
  the aggregator surface (§4.1, §8.2 last paragraph).
  """
  @spec configured_aggregator_mode?() :: boolean()
  def configured_aggregator_mode? do
    RootUpstreamRuntime.configured?()
  end

  defp current_profile do
    if configured_aggregator_mode?(), do: :mcp_aggregator, else: :mcp_no_tools
  end

  defp annotations_for(:mcp_no_tools) do
    %{
      "readOnlyHint" => true,
      "destructiveHint" => false,
      "idempotentHint" => true,
      "openWorldHint" => false
    }
  end

  # Phase 1a §8.2: aggregator mode is conservative by default because
  # configured upstreams may delete or mutate. `--aggregator-read-only`
  # is an operator assertion for read-only upstream configurations; it
  # changes annotations only, not enforcement.
  defp annotations_for(:mcp_aggregator) do
    if AggregatorConfig.read_only?() do
      %{
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => false,
        "openWorldHint" => true
      }
    else
      %{
        "readOnlyHint" => false,
        "destructiveHint" => true,
        "idempotentHint" => false,
        "openWorldHint" => true
      }
    end
  end

  @doc "The `lisp_eval` tool entry returned in `tools/list`."
  @spec tool_entry() :: map()
  def tool_entry do
    capability_profile = current_profile()
    response_profile = ResponseProfile.current()

    %{
      "name" => @tool_name,
      "description" =>
        advertised_description(capability_profile, response_profile,
          catalog: catalog_for(capability_profile)
        ),
      "inputSchema" => input_schema_for(capability_profile),
      "annotations" => annotations_for(capability_profile)
    }
    |> maybe_put_output_schema(output_schema_for(capability_profile, response_profile))
  end

  # §5/§6: mode-aware catalog description. The frozen snapshot
  # (populated at boot by Upstream.Supervisor) is read by
  # CatalogDescription, which resolves the effective mode (auto,
  # inline, lazy) and renders the appropriate description fragment.
  defp catalog_for(:mcp_no_tools), do: nil

  defp catalog_for(:mcp_aggregator) do
    if RootUpstreamRuntime.configured?() do
      RootUpstreamRuntime.catalog_text()
    else
      CatalogDescription.render()
    end
  end

  @doc "Handle a `tools/list` request."
  @spec list() :: map()
  def list do
    base =
      if Sessions.enabled?() do
        []
      else
        [tool_entry()]
      end

    base =
      if agentic_advertised?() do
        base ++ [Agentic.tool_entry()]
      else
        base
      end

    tools =
      if PtcRunnerMcp.DebugConfig.enabled?() do
        base ++ [PtcRunnerMcp.DebugTool.tool_entry()]
      else
        base
      end

    %{"tools" => tools ++ Sessions.tool_entries()}
  end

  @doc false
  @spec agentic_advertised?() :: boolean()
  def agentic_advertised? do
    configured_aggregator_mode?() and AgenticConfig.enabled?()
  end

  @doc """
  Handle a `tools/call` request.

  For `name: "lisp_eval"`, validates `program` (§ 9.2),
  `context` and `output_schema` before acquiring a
  concurrency permit. All argument-shape failures emit `args_error`
  without consuming a permit. The permit is held only while the
  underlying `Lisp.run/2` is in flight and is released even on
  validation error after execution.

  For any other name, returns an `unknown_tool` envelope per § 7.4
  D1 (NOT JSON-RPC `-32601`).

  ## Gate ownership

  Phase 4 moves `tools/call` execution into per-call worker processes
  spawned by `PtcRunnerMcp.Stdio` (§ 6.3, § 11). The serial-dispatch
  comment that lived here in Phase 2 is gone: the stdio reader now
  acquires the concurrency permit synchronously *before* spawning the
  worker, and releases it when the worker exits (normally or via
  `notifications/cancelled`). `Tools.call/1` keeps the legacy permit
  acquire/release for direct in-process callers (and tests); the
  worker path uses `call_validated/3` to skip the gate (the stdio
  reader owns it). See `Stdio.handle_async_call/4`.
  """
  @spec call(map()) :: map()
  def call(%{"name" => @tool_name, "arguments" => args}) when is_map(args) do
    if Sessions.enabled?() do
      Envelope.unknown_tool(@tool_name)
    else
      handle_execute_with_gate(args)
    end
  end

  def call(%{"name" => @tool_name}) do
    if Sessions.enabled?() do
      Envelope.unknown_tool(@tool_name)
    else
      handle_execute_with_gate(%{})
    end
  end

  def call(%{"name" => "lisp_task", "arguments" => args}) when is_map(args),
    do: handle_agentic_call(args)

  def call(%{"name" => "lisp_task"}), do: handle_agentic_call(%{})

  def call(%{"name" => name} = params) when is_binary(name) do
    if Sessions.tool_name?(name) do
      Sessions.call(params)
    else
      Envelope.unknown_tool(name)
    end
  end

  def call(_), do: Envelope.unknown_tool("")

  @doc false
  @spec validate_session_eval(map()) :: {:ok, map()} | {:error, map()}
  def validate_session_eval(args) when is_map(args), do: Sessions.validate_eval(args)

  @doc false
  @spec call_session_eval_validated(map(), keyword()) :: map()
  def call_session_eval_validated(validated, opts \\ []) when is_map(validated) do
    Sessions.eval_validated(validated, opts)
  end

  @doc false
  @spec call_session_eval_reserved(map(), keyword()) :: map()
  def call_session_eval_reserved(reservation, opts \\ []) when is_map(reservation) do
    Sessions.eval_reserved(reservation, opts)
  end

  @doc false
  @spec abort_session_eval_reserved(map(), term()) :: :ok | {:error, map()}
  def abort_session_eval_reserved(reservation, reason) when is_map(reservation) do
    Sessions.abort_reserved_eval(reservation, reason)
  end

  @doc """
  Validate the inner `arguments` map for `tools/call name:
  "lisp_eval"`.

  Returns `{:ok, program, context, parsed_signature}` when all three
  argument-shape checks pass, or `{:error, envelope}` with the
  rendered `args_error` envelope when any fails. Used by
  `PtcRunnerMcp.Stdio` to short-circuit malformed requests *before*
  acquiring a concurrency permit (§ 9 / § 11).
  """
  @spec validate(map()) ::
          {:ok, String.t(), map(), Sandbox.parsed_signature()} | {:error, map()}
  def validate(args) when is_map(args) do
    with {:ok, program} <- validate_program(args),
         {:ok, context} <- validate_context(args),
         {:ok, parsed_signature} <- validate_output_contract(args) do
      {:ok, program, context, parsed_signature}
    else
      {:error, message} ->
        payload = Envelope.render_error_payload(:args_error, message)
        {:error, Envelope.ptc_lisp_error(payload)}
    end
  end

  @doc """
  Run an already-validated `tools/call` invocation WITHOUT acquiring a
  concurrency permit.

  Used by the per-call worker spawned in `PtcRunnerMcp.Stdio`: stdio
  acquires the permit before spawning, and releases it when the worker
  exits. `Sandbox.execute/4` is invoked with `link: true` so a worker
  killed by `notifications/cancelled` takes its sandbox child with it
  via the link signal (rather than letting the orphaned sandbox
  process run until its own heap/timeout limit).

  Per `Plans/ptc-runner-mcp-aggregator.md` §11.3, this function is
  the **MCP request handler decoration point**: it receives the
  unwrapped `{kind, payload}` from `Sandbox.execute/4` and wraps via
  `Envelope.success/1` or `Envelope.error_envelope/1`. Phase 1a
  inserts the `upstream_calls` decoration between the two steps.
  """
  @spec call_validated(String.t(), map(), Sandbox.parsed_signature(), keyword()) :: map()
  def call_validated(program, context, parsed_signature, opts \\ [])
      when is_binary(program) and is_map(context) and is_list(opts) do
    request_id = Keyword.get(opts, :request_id)

    execute_with_aggregator(
      program,
      context,
      parsed_signature,
      [link: true],
      request_id: request_id
    )
  end

  @doc """
  Acquire-then-execute for in-process callers. Returns `:busy`
  envelope if `:max_concurrent_calls` is exceeded.

  Stdio does NOT use this — it owns the gate itself. This entry
  point exists for tests and any direct in-VM caller that wants
  end-to-end semantics in one shot.
  """
  @spec call_with_gate(map()) :: map()
  def call_with_gate(args) when is_map(args) do
    handle_execute_with_gate(args)
  end

  @doc false
  @spec call_agentic_validated(map(), keyword()) :: map()
  def call_agentic_validated(validated, opts \\ []) when is_map(validated) do
    Agentic.run_validated(validated, opts)
  end

  defp handle_execute_with_gate(args) do
    case validate(args) do
      {:ok, program, context, parsed_signature} ->
        run_with_gate(program, context, parsed_signature)

      {:error, envelope} ->
        envelope
    end
  end

  defp handle_agentic_with_gate(args) do
    case Agentic.validate(args) do
      {:ok, validated} ->
        run_agentic_with_gate(validated)

      {:error, envelope} ->
        envelope
    end
  end

  defp handle_agentic_call(args) do
    if agentic_advertised?() do
      handle_agentic_with_gate(args)
    else
      Envelope.unknown_tool("lisp_task")
    end
  end

  defp run_agentic_with_gate(validated) do
    cap = Limits.max_concurrent_calls()

    case ConcurrencyGate.try_acquire(cap) do
      :ok ->
        try do
          Agentic.run_validated(validated, request_id: nil)
        after
          ConcurrencyGate.release()
        end

      :full ->
        Envelope.busy(cap)
    end
  end

  defp run_with_gate(program, context, parsed_signature) do
    cap = Limits.max_concurrent_calls()

    # Phase 4: this entry point is for direct in-process callers and
    # tests. The MCP stdio reader does NOT call this — it owns the
    # gate itself (acquire before spawn, release on worker DOWN) so a
    # worker killed by `notifications/cancelled` cannot leak permits
    # via a skipped `try/after` cleanup. See `Stdio.handle_async_call/4`.
    case ConcurrencyGate.try_acquire(cap) do
      :ok ->
        try do
          # In-process / test callers don't carry a JSON-RPC
          # request id; telemetry metadata gets `request_id: nil`.
          execute_with_aggregator(program, context, parsed_signature, [], request_id: nil)
        after
          ConcurrencyGate.release()
        end

      :full ->
        Envelope.busy(cap)
    end
  end

  # Phase 1a §11.3 + §6.4 decoration seam.
  #
  # In `:mcp_no_tools` mode, this is the same single-step Sandbox.execute
  # → wrap_sandbox_result pipeline as Phase 0 — `:tools` defaults to
  # `[]` and no upstream_calls drain happens.
  #
  # In aggregator mode, the request handler:
  #   1. Builds a fresh `call_context` (unique ref + :counters cap).
  #   2. Registers the `call` virtual tool whose closure captures
  #      that context.
  #   3. Runs `Sandbox.execute(..., tools: %{"call" => closure},
  #      profile: :mcp_aggregator)`.
  #   4. On normal completion or caught Lisp/runtime error producing
  #      an envelope, drains the worker's mailbox for
  #      `{:upstream_call_recorded, ref, entry}` messages, decorates
  #      the v1 payload with `upstream_calls`, and only then wraps
  #      via `Envelope.success/1` or `Envelope.error_envelope/1`.
  #      Cancellation / worker crash skips the drain (§6.4 last
  #      paragraph) — this code path simply isn't reached.
  defp execute_with_aggregator(program, context, parsed_signature, sandbox_opts, _exec_opts) do
    if RootUpstreamRuntime.configured?() do
      execute_with_root_runtime(program, context, parsed_signature, sandbox_opts)
    else
      program
      |> Sandbox.execute(context, parsed_signature, sandbox_opts)
      |> wrap_sandbox_result()
    end
  end

  defp execute_with_root_runtime(program, context, parsed_signature, sandbox_opts) do
    runtime = RootUpstreamRuntime.runtime()

    {:ok, run_context} =
      Eval.run_context(runtime,
        max_tool_calls: Limits.max_upstream_calls_per_program(),
        max_catalog_ops: CatalogConfig.get().max_catalog_ops_per_program,
        call_timeout_ms: Limits.upstream_call_timeout_ms(),
        max_response_bytes: Limits.max_upstream_response_bytes(),
        max_catalog_result_bytes: CatalogConfig.get().max_catalog_result_bytes
      )

    try do
      eval_opts = Eval.eval_options(run_context)

      sandbox_result =
        Sandbox.execute(
          program,
          context,
          parsed_signature,
          [
            tools: eval_opts[:tools],
            discovery_exec: eval_opts[:discovery_exec],
            runtime: runtime,
            profile: :mcp_aggregator
          ] ++
            sandbox_opts
        )

      entries = RunContext.drain_calls(run_context)
      decorate_and_wrap(sandbox_result, entries)
    after
      RunContext.close(run_context)
    end
  end

  defp decorate_and_wrap({:ok, payload}, entries) when is_map(payload) do
    profile = ResponseProfile.current()

    case profile do
      :debug ->
        payload
        |> Result.decorate_payload(entries)
        |> decorate_ptc_metrics(:ok, entries)
        |> OutputLimits.shape_lisp_payload(:ok, profile)
        |> Envelope.ptc_lisp_success()
        |> OutputLimits.limit_envelope(profile)

      _ ->
        debug_payload =
          payload
          |> Result.decorate_payload(entries)
          |> decorate_ptc_metrics(:ok, entries)

        payload
        |> OutputLimits.shape_lisp_payload(:ok, profile)
        |> Envelope.ptc_lisp_success()
        |> OutputLimits.limit_envelope(profile)
        |> maybe_attach_debug_structured(debug_payload)
    end
  end

  defp decorate_and_wrap({:error, payload}, entries) when is_map(payload) do
    decorated =
      payload
      |> UpstreamResultFeedback.append_to_feedback(entries)
      |> Result.decorate_payload(entries)

    profile = ResponseProfile.current()

    case profile do
      :debug ->
        decorated
        |> decorate_ptc_metrics(:error, entries)
        |> OutputLimits.shape_lisp_payload(:error, profile)
        |> Envelope.ptc_lisp_error()
        |> OutputLimits.limit_envelope(profile)

      _ ->
        debug_payload = decorate_ptc_metrics(decorated, :error, entries)

        decorated
        |> OutputLimits.shape_lisp_payload(:error, profile)
        |> Envelope.ptc_lisp_error()
        |> OutputLimits.limit_envelope(profile)
        |> maybe_attach_debug_structured(debug_payload)
    end
  end

  # `Plans/ptc-runner-mcp-payload-reduction.md` §4.2 / §7 #8: attach
  # `ptc_metrics` only in the `:mcp_aggregator` profile (this code path
  # is aggregator-only) and only when the program made ≥ 1 upstream
  # call — a pure-compute program has nothing to measure. On error,
  # `final_result_bytes` is always 0 — the error payload can carry a
  # `result` *preview* of the failed value (the `(fail ...)` path), but
  # that is not "the answer the program produced" (§7 #9), so the ratio
  # degrades to `null` (§7 #2).
  defp decorate_ptc_metrics(payload, _kind, []) when is_map(payload), do: payload

  defp decorate_ptc_metrics(payload, kind, entries)
       when is_map(payload) and kind in [:ok, :error] and is_list(entries) do
    final_result_bytes = if kind == :ok, do: result_field_bytes(payload), else: 0
    prints_bytes = prints_field_bytes(payload)

    Map.put(
      payload,
      "ptc_metrics",
      PayloadMetrics.build(final_result_bytes, prints_bytes, entries)
    )
  end

  # `final_result_bytes` (success envelopes only): byte size of the
  # `result` field returned to the client (a string preview of the
  # program's answer; absent when both the rendered value and the
  # program's return are `nil` — see
  # `PtcRunner.PtcToolProtocol.render_success/2`). 0 then.
  defp result_field_bytes(%{"result" => r}) when is_binary(r), do: byte_size(r)
  defp result_field_bytes(_), do: 0

  # `prints_bytes`: byte size of the serialized `prints` array, kept
  # separate so the headline ratio isn't muddied by debug prints.
  # Re-encode failure (vanishingly rare for an already-decoded list)
  # collapses to 0.
  defp prints_field_bytes(%{"prints" => p}) when is_list(p) do
    case Jason.encode(p) do
      {:ok, json} -> byte_size(json)
      {:error, _} -> 0
    end
  end

  defp prints_field_bytes(_), do: 0

  # Phase 0 §11.3 decoration seam: `Sandbox.execute/4` returns the
  # **unwrapped** v1 structured payload as `{:ok | :error, payload}`.
  # The MCP request handler — `call_validated/3` and `run_with_gate/3`
  # above — wraps it here. Phase 1a will insert
  #
  #     payload = decorate_with_upstream_calls(payload, drain(...))
  #
  # between `Sandbox.execute` and this wrap. Keeping the wrap in one
  # place means Phase 1a touches a single function rather than
  # scattering decoration through Sandbox renderers.
  # Mirrors the slim-profile attach in `decorate_and_wrap/2`: in a
  # non-debug profile this path still hands the pre-slim payload to the
  # debug recorder (via `__lisp_debug_structured`) when `--debug-tool`
  # is on, so a `--debug-tool --response-profile slim` server keeps
  # full diagnostics even for no-upstream executions.
  defp wrap_sandbox_result({:ok, payload}) when is_map(payload) do
    profile = ResponseProfile.current()

    case profile do
      :debug ->
        payload
        |> OutputLimits.shape_lisp_payload(:ok, profile)
        |> Envelope.ptc_lisp_success()
        |> OutputLimits.limit_envelope(profile)

      _ ->
        payload
        |> OutputLimits.shape_lisp_payload(:ok, profile)
        |> Envelope.ptc_lisp_success()
        |> OutputLimits.limit_envelope(profile)
        |> maybe_attach_debug_structured(payload)
    end
  end

  defp wrap_sandbox_result({:error, payload}) when is_map(payload) do
    profile = ResponseProfile.current()

    case profile do
      :debug ->
        payload
        |> OutputLimits.shape_lisp_payload(:error, profile)
        |> Envelope.ptc_lisp_error()
        |> OutputLimits.limit_envelope(profile)

      _ ->
        payload
        |> OutputLimits.shape_lisp_payload(:error, profile)
        |> Envelope.ptc_lisp_error()
        |> OutputLimits.limit_envelope(profile)
        |> maybe_attach_debug_structured(payload)
    end
  end

  # § 9.2: missing → not a string → empty after trim → too large.
  defp validate_program(args) do
    case Map.fetch(args, "program") do
      :error ->
        {:error, "argument `program` is required"}

      {:ok, value} when not is_binary(value) ->
        {:error, "argument `program` must be a string, got #{type_label(value)}"}

      {:ok, value} ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" ->
            {:error, "argument `program` must be a non-empty string"}

          byte_size(value) > Limits.max_program_bytes() ->
            {:error,
             "argument `program` exceeds max_program_bytes (" <>
               Integer.to_string(byte_size(value)) <>
               " > " <>
               Integer.to_string(Limits.max_program_bytes()) <> ")"}

          true ->
            {:ok, value}
        end
    end
  end

  # § 9.3: validate `context` shape, key syntax, and encoded byte size.
  # On success returns the same map (Jason already gave us binaries,
  # integers, floats, lists, maps — exactly what `Lisp.run/2`'s
  # `:context` opt expects).
  defp validate_context(args) do
    case Map.fetch(args, "context") do
      :error ->
        {:ok, %{}}

      {:ok, nil} ->
        {:ok, %{}}

      {:ok, value} when not is_map(value) or is_struct(value) ->
        {:error, "argument `context` must be a JSON object, got #{type_label(value)}"}

      {:ok, value} ->
        with :ok <- check_context_size(value),
             :ok <- check_context_keys(value) do
          {:ok, value}
        end
    end
  end

  defp check_context_size(map) do
    case Jason.encode(map) do
      {:ok, encoded} ->
        size = byte_size(encoded)
        cap = Limits.max_context_bytes()

        if size > cap do
          {:error,
           "argument `context` exceeds max_context_bytes (" <>
             Integer.to_string(size) <> " > " <> Integer.to_string(cap) <> ")"}
        else
          :ok
        end

      {:error, reason} ->
        {:error, "argument `context` is not JSON-encodable: #{inspect(reason)}"}
    end
  end

  defp check_context_keys(map) do
    Enum.reduce_while(map, :ok, fn {k, _v}, _acc ->
      cond do
        not is_binary(k) ->
          {:halt, {:error, "argument `context` keys must be strings (got: #{inspect(k)})"}}

        k == "" ->
          {:halt, {:error, "argument `context` keys must be non-empty"}}

        String.contains?(k, "/") ->
          {:halt,
           {:error,
            "argument `context` keys may not contain `/` (would shadow PTC-Lisp namespace): #{inspect(k)}"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  @doc """
  Parse the `output_schema` argument from an MCP tools/call arguments map.

  Returns `{:ok, parsed_signature}` (or `{:ok, nil}` when neither was
  supplied) or `{:error, message}`. Public so `PtcRunnerMcp.Sessions`
  can reuse the same gate from `lisp_session_eval` validation.
  """
  @spec validate_output_contract(map()) ::
          {:ok, Sandbox.parsed_signature() | nil} | {:error, String.t()}
  def validate_output_contract(args) when is_map(args) do
    case Map.fetch(args, "signature") do
      {:ok, _value} ->
        {:error, "argument `signature` is no longer supported; use `output_schema`"}

      :error ->
        validate_output_schema(args)
    end
  end

  defp validate_output_schema(args) do
    case Map.fetch(args, "output_schema") do
      {:ok, value} when not is_map(value) or is_struct(value) ->
        {:error, "argument `output_schema` must be a JSON object, got #{type_label(value)}"}

      {:ok, value} ->
        case Signature.from_json_schema(value) do
          {:ok, return_type} -> {:ok, {:signature, [], return_type}}
          {:error, reason} -> {:error, "argument `output_schema` is invalid: #{reason}"}
        end

      :error ->
        {:ok, nil}
    end
  end

  defp type_label(v) when is_struct(v), do: "struct"
  defp type_label(v) when is_map(v), do: "object"
  defp type_label(v) when is_list(v), do: "array"
  defp type_label(v) when is_integer(v), do: "integer"
  defp type_label(v) when is_float(v), do: "number"
  defp type_label(v) when is_boolean(v), do: "boolean"
  defp type_label(nil), do: "null"
  defp type_label(_), do: "unknown"

  defp input_schema_for(profile) when profile in [:mcp_no_tools, :mcp_aggregator] do
    %{
      "type" => "object",
      "properties" => %{
        "program" => %{
          "type" => "string",
          "description" => "PTC-Lisp source code. Must be non-empty after trimming whitespace."
        },
        "context" => %{
          "type" => "object",
          "description" =>
            "Optional map of named values bound under data/ in the program. " <>
              "Keys are strings; values are JSON-encodable.",
          "additionalProperties" => true
        },
        "output_schema" => %{
          "type" => "object",
          "description" => output_schema_description_for(profile)
        }
      },
      "required" => ["program"]
    }
  end

  defp output_schema_description_for(:mcp_no_tools) do
    ~s|Optional JSON Schema for return validation. The response carries a structured | <>
      ~s|`validated` JSON value when supplied. Supported types: string, integer, number, | <>
      ~s|boolean, array (with items), object (with properties/required). | <>
      ~s|Example: {"type": "object", "properties": {"count": {"type": "integer"}}, | <>
      ~s|"required": ["count"]}.|
  end

  defp output_schema_description_for(:mcp_aggregator) do
    "Optional JSON Schema for return validation. Omit for exploratory upstream calls. " <>
      "Supported types: string, integer, number, boolean, array (with items), " <>
      "object (with properties/required)."
  end

  defp prepend_response_profile_note(description, capability_profile, :slim) do
    profile_note =
      "Response profile: slim. Successful calls return concise human-readable text " <>
        "in content[0].text and do not include structuredContent or outputSchema. " <>
        "Use --response-profile structured for compact machine-readable results, or " <>
        "--debug-tool for diagnostic details."

    aggregator_note =
      case capability_profile do
        :mcp_aggregator ->
          " Upstream world faults return tagged {:ok false ...} values inside the PTC-Lisp program; unhandled " <>
            "repairable failures are summarized in error text."

        _ ->
          ""
      end

    case capability_profile do
      :mcp_aggregator -> description <> "\n\n" <> profile_note <> aggregator_note
      _ -> profile_note <> "\n\n" <> description
    end
  end

  defp prepend_response_profile_note(description, :mcp_aggregator, :structured) do
    description <>
      "\n\nResponse profile: structured. Calls return compact structuredContent with concise " <>
      "human-readable text; debug-only observability fields are omitted."
  end

  defp prepend_response_profile_note(description, _capability_profile, :structured) do
    "Response profile: structured. Calls return compact structuredContent with concise " <>
      "human-readable text; debug-only observability fields are omitted.\n\n" <> description
  end

  defp prepend_response_profile_note(description, _capability_profile, :debug), do: description

  defp maybe_put_output_schema(tool, nil), do: tool
  defp maybe_put_output_schema(tool, schema), do: Map.put(tool, "outputSchema", schema)

  defp maybe_attach_debug_structured(envelope, structured) do
    if DebugConfig.enabled?() do
      Map.put(envelope, "__lisp_debug_structured", structured)
    else
      envelope
    end
  end
end
