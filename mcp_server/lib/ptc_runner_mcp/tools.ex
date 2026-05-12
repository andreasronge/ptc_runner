defmodule PtcRunnerMcp.Tools do
  @moduledoc """
  `tools/list` and `tools/call` handlers.

  Per `Plans/ptc-runner-mcp-server.md` § 8.1, the server advertises
  exactly one tool, `ptc_lisp_execute`. The advertised description is
  the canonical `:mcp_no_tools` profile string from
  `PtcRunner.PtcToolProtocol`, followed by exactly two newlines, then
  the package-owned authoring card (§ 8.4).

  Phase 2 wired real `Lisp.run/2` execution through
  `PtcRunnerMcp.Sandbox` and enforced `:max_program_bytes` and
  `:max_concurrent_calls` (§ 11). Phase 3 wires the remaining two
  arguments per § 9.3 / § 9.4:

    * `context` — JSON object whose keys land as `data/<key>` bindings
      inside the program. Validated for shape, key syntax, and
      encoded byte size before a concurrency permit is acquired.
    * `signature` — PTC signature string, parsed via
      `PtcToolProtocol.parse_signature/1` and used for return-value
      validation only. Parse failure is `args_error`; mismatch
      between the parsed signature and the program's return is
      `validation_error`.

  Both validations short-circuit before `ConcurrencyGate.try_acquire/1`
  so a malformed argument never consumes a permit.
  """

  alias PtcRunner.PtcToolProtocol

  alias PtcRunnerMcp.{
    Agentic,
    AgenticConfig,
    AggregatorTools,
    ConcurrencyGate,
    Envelope,
    Limits,
    PayloadMetrics,
    Sandbox,
    UpstreamCalls
  }

  alias PtcRunnerMcp.AggregatorConfig
  alias PtcRunnerMcp.Upstream.Catalog, as: UpstreamCatalog
  alias PtcRunnerMcp.Upstream.Registry, as: UpstreamRegistry

  @tool_name "ptc_lisp_execute"

  # Compile-time read of the authoring card per § 8.4. The
  # `@external_resource` attribute tells BEAM to recompile this module
  # whenever the file changes. We resolve the path relative to this
  # source file rather than via `:code.priv_dir/1` because the app may
  # not yet be loaded at compile time.
  @priv_path Path.expand(Path.join([__DIR__, "..", "..", "priv", "mcp_authoring_card.md"]))
  @external_resource @priv_path
  @authoring_card File.read!(@priv_path)

  # Phase 1a §8.1: aggregator mode advertises a different authoring
  # card describing `(tool/mcp-call ...)`, the `nil` failure convention,
  # the `:json-null` sentinel, and the `upstream_calls` envelope field.
  @aggregator_priv_path Path.expand(
                          Path.join([
                            __DIR__,
                            "..",
                            "..",
                            "priv",
                            "mcp_aggregator_authoring_card.md"
                          ])
                        )
  @external_resource @aggregator_priv_path
  @aggregator_authoring_card File.read!(@aggregator_priv_path)

  # Aggregator-mode capability statement. Adapted from the v1
  # `:mcp_no_tools` description so the aggregator advertisement stays
  # consistent in tone but accurately reflects the new capability:
  # "this server can call configured upstream MCP tools from inside
  # the sandbox." Per §8.1 the description is one constant + the
  # authoring card; per §11.1 the catalog injection seam (Phase 3)
  # is the `opts` keyword.
  @mcp_aggregator_description ~s|Execute a PTC-Lisp program in PtcRunner's sandbox. Use this for deterministic computation, filtering, aggregation, and orchestration over configured upstream MCP servers. Call upstream tools as `(tool/mcp-call {:server "<name>" :tool "<tool>" :args {...}})` from inside the program. World-fault failures (timeout, oversize, upstream error, cap, unavailable) return `nil` and are recorded in `upstream_calls` on the response envelope. Each invocation of `ptc_lisp_execute` is independent — there is no memory of prior calls.|

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
          "validated" => %{}
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
          "result" => %{"type" => "string"}
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
            "upstream_error",
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
          |> Map.put("ptc_metrics", @ptc_metrics_schema)
        end)
      end)
  }

  @doc """
  The verbatim authoring-card markdown shipped at
  `mcp_server/priv/mcp_authoring_card.md`.

  Read at compile time via `@external_resource`; edits to the source
  file trigger a recompile of this module.
  """
  @spec authoring_card() :: String.t()
  def authoring_card, do: @authoring_card

  @doc """
  The advertised `description` field for the `ptc_lisp_execute` tool,
  by capability profile.

  Phase 0 (`Plans/ptc-runner-mcp-aggregator.md` §11.1) refactors the
  former `advertised_description/0` into a profile-aware builder.
  For `:mcp_no_tools`, the output is byte-for-byte identical to v1:

      tool_description(:mcp_no_tools) <> "\\n\\n" <> authoring_card()

  The `opts` keyword is the seam aggregator mode will use to inject
  runtime catalog text in Phase 3 (`catalog: catalog_string_or_nil`).
  Phase 0 accepts and ignores `:catalog`; future profiles
  (`:mcp_aggregator`) consume it.
  """
  @spec advertised_description(profile :: atom(), opts :: keyword()) :: String.t()
  def advertised_description(profile, opts \\ [])

  def advertised_description(:mcp_no_tools, _opts) do
    PtcToolProtocol.tool_description(:mcp_no_tools) <> "\n\n" <> authoring_card()
  end

  # Phase 1a §8.1: aggregator description = capability statement +
  # aggregator authoring card. The `:catalog` opt is the seam Phase 3
  # will use to inject an inline upstream catalog; for Phases 1a-2,
  # `catalog: nil` is acceptable per §8.1.
  def advertised_description(:mcp_aggregator, opts) do
    catalog = Keyword.get(opts, :catalog)

    base = @mcp_aggregator_description <> "\n\n" <> aggregator_authoring_card()

    case catalog do
      nil -> base
      "" -> base
      str when is_binary(str) -> base <> "\n\n" <> str
    end
  end

  @doc """
  The verbatim aggregator-mode authoring-card markdown shipped at
  `mcp_server/priv/mcp_aggregator_authoring_card.md`. Read at compile
  time via `@external_resource`.
  """
  @spec aggregator_authoring_card() :: String.t()
  def aggregator_authoring_card, do: @aggregator_authoring_card

  @doc """
  Backward-compatible alias for `advertised_description(:mcp_no_tools, [])`.

  Existing call sites (and test suites) use the 0-arity form; Phase 0
  preserves it as a thin wrapper so the v1 MCP profile reads
  identically before and after the §11.1 refactor.
  """
  @spec advertised_description() :: String.t()
  def advertised_description, do: advertised_description(:mcp_no_tools, catalog: nil)

  @doc """
  The advertised `outputSchema` for the `ptc_lisp_execute` tool, by
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
    case Process.whereis(UpstreamRegistry) do
      nil ->
        false

      pid when is_pid(pid) ->
        try do
          UpstreamRegistry.configured_count() > 0
        catch
          :exit, _ -> false
        end
    end
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

  @doc "The `ptc_lisp_execute` tool entry returned in `tools/list`."
  @spec tool_entry() :: map()
  def tool_entry do
    profile = current_profile()

    %{
      "name" => @tool_name,
      "description" => advertised_description(profile, catalog: catalog_for(profile)),
      "inputSchema" => input_schema_for(profile),
      "outputSchema" => output_schema_for(profile),
      "annotations" => annotations_for(profile)
    }
  end

  # §12.5: read the FROZEN catalog from `:persistent_term`. The
  # Phase 0 `:mcp_no_tools` fixture is byte-equal-protected by
  # `tools_phase0_test.exs` — that profile MUST keep `catalog: nil`
  # so the v1 tool_entry snapshot is unchanged.
  #
  # The catalog string is rendered ONCE at boot (in
  # `Upstream.Supervisor.start_link/1` after `eager_start_upstreams/1`)
  # and stored via `Catalog.freeze/1`. This satisfies §12.5's
  # "rebuilt only on PtcRunner restart" contract: post-boot upstream
  # crashes, recoveries, and `put_fake/2` calls do NOT change the
  # catalog text the calling LLM sees.
  #
  # `Catalog.frozen/0` returns `""` when no catalog has been frozen
  # (non-aggregator mode, or a boot path where the supervisor was
  # never started). `advertised_description/2` already maps `""` to
  # "no catalog block", so the description still renders cleanly.
  defp catalog_for(:mcp_no_tools), do: nil

  defp catalog_for(:mcp_aggregator) do
    case UpstreamCatalog.frozen() do
      "" -> nil
      str when is_binary(str) -> str
    end
  end

  @doc "Handle a `tools/list` request."
  @spec list() :: map()
  def list do
    base =
      if agentic_advertised?() do
        [tool_entry(), Agentic.tool_entry()]
      else
        [tool_entry()]
      end

    tools =
      if PtcRunnerMcp.DebugConfig.enabled?() do
        base ++ [PtcRunnerMcp.DebugTool.tool_entry()]
      else
        base
      end

    %{"tools" => tools}
  end

  @doc false
  @spec agentic_advertised?() :: boolean()
  def agentic_advertised? do
    configured_aggregator_mode?() and AgenticConfig.enabled?()
  end

  @doc """
  Handle a `tools/call` request.

  For `name: "ptc_lisp_execute"`, validates `program` (§ 9.2),
  `context` (§ 9.3), and `signature` (§ 9.4) before acquiring a
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
    handle_execute_with_gate(args)
  end

  def call(%{"name" => @tool_name}), do: handle_execute_with_gate(%{})

  def call(%{"name" => "ptc_task", "arguments" => args}) when is_map(args),
    do: handle_agentic_call(args)

  def call(%{"name" => "ptc_task"}), do: handle_agentic_call(%{})

  def call(%{"name" => name}) when is_binary(name), do: Envelope.unknown_tool(name)
  def call(_), do: Envelope.unknown_tool("")

  @doc """
  Validate the inner `arguments` map for `tools/call name:
  "ptc_lisp_execute"`.

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
         {:ok, parsed_signature} <- validate_signature(args) do
      {:ok, program, context, parsed_signature}
    else
      {:error, message} -> {:error, Envelope.render_error(:args_error, message)}
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
      Envelope.unknown_tool("ptc_task")
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
  #   2. Registers the `mcp-call` virtual tool whose closure captures
  #      that context.
  #   3. Runs `Sandbox.execute(..., tools: %{"mcp-call" => closure},
  #      profile: :mcp_aggregator)`.
  #   4. On normal completion or caught Lisp/runtime error producing
  #      an envelope, drains the worker's mailbox for
  #      `{:upstream_call_recorded, ref, entry}` messages, decorates
  #      the v1 payload with `upstream_calls`, and only then wraps
  #      via `Envelope.success/1` or `Envelope.error_envelope/1`.
  #      Cancellation / worker crash skips the drain (§6.4 last
  #      paragraph) — this code path simply isn't reached.
  defp execute_with_aggregator(program, context, parsed_signature, sandbox_opts, exec_opts) do
    if configured_aggregator_mode?() do
      request_id = Keyword.get(exec_opts, :request_id)

      call_context =
        UpstreamCalls.new_call_context(
          collector_pid: self(),
          collector_ref: make_ref(),
          max_calls: Limits.max_upstream_calls_per_program(),
          call_timeout_ms: Limits.upstream_call_timeout_ms(),
          max_response_bytes: Limits.max_upstream_response_bytes()
        )

      # Thread `request_id` into the closure so
      # `[:ptc_runner_mcp, :upstream, :call, :*]` telemetry metadata
      # carries the originating MCP request id. Operators correlating
      # upstream call failures back to the parent `tools/call` use
      # this as the join key.
      tools = AggregatorTools.build(call_context, request_id: request_id)

      sandbox_result =
        Sandbox.execute(
          program,
          context,
          parsed_signature,
          [tools: tools, profile: :mcp_aggregator] ++ sandbox_opts
        )

      entries = UpstreamCalls.drain(call_context.collector_ref)
      decorate_and_wrap(sandbox_result, entries)
    else
      program
      |> Sandbox.execute(context, parsed_signature, sandbox_opts)
      |> wrap_sandbox_result()
    end
  end

  defp decorate_and_wrap({:ok, payload}, entries) when is_map(payload) do
    payload
    |> UpstreamCalls.decorate(entries)
    |> decorate_ptc_metrics(entries)
    |> Envelope.success()
  end

  defp decorate_and_wrap({:error, payload}, entries) when is_map(payload) do
    payload
    |> UpstreamCalls.decorate(entries)
    |> decorate_ptc_metrics(entries)
    |> Envelope.error_envelope()
  end

  # `Plans/ptc-runner-mcp-payload-reduction.md` §4.2 / §7 #8: attach
  # `ptc_metrics` only in the `:mcp_aggregator` profile (this code path
  # is aggregator-only) and only when the program made ≥ 1 upstream
  # call — a pure-compute program has nothing to measure. On error the
  # `result` field is absent, so `final_result_bytes` is 0 and the
  # ratio degrades to `null` (§7 #2, #9).
  defp decorate_ptc_metrics(payload, []) when is_map(payload), do: payload

  defp decorate_ptc_metrics(payload, entries) when is_map(payload) and is_list(entries) do
    final_result_bytes = result_field_bytes(payload)
    prints_bytes = prints_field_bytes(payload)

    Map.put(
      payload,
      "ptc_metrics",
      PayloadMetrics.build(final_result_bytes, prints_bytes, entries)
    )
  end

  # `final_result_bytes`: byte size of the `result` field returned to
  # the client (a string preview of the program's answer; absent on
  # error or when both the rendered value and the program's return are
  # `nil` — see `PtcRunner.PtcToolProtocol.render_success/2`). 0 in
  # those cases.
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
  defp wrap_sandbox_result({:ok, payload}) when is_map(payload), do: Envelope.success(payload)

  defp wrap_sandbox_result({:error, payload}) when is_map(payload),
    do: Envelope.error_envelope(payload)

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

  # § 9.4: validate that `signature`, when present, is a string and
  # parses cleanly. Parse failure short-circuits BEFORE permit
  # acquisition.
  defp validate_signature(args) do
    case Map.fetch(args, "signature") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when not is_binary(value) ->
        {:error, "argument `signature` must be a string, got #{type_label(value)}"}

      {:ok, value} ->
        if String.trim(value) == "any" do
          {:ok, nil}
        else
          case PtcToolProtocol.parse_signature(value) do
            {:ok, parsed} -> {:ok, parsed}
            {:error, reason} -> {:error, "argument `signature` is malformed: #{reason}"}
          end
        end
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
        "signature" => %{
          "type" => "string",
          "description" => signature_description_for(profile)
        }
      },
      "required" => ["program"]
    }
  end

  defp signature_description_for(:mcp_no_tools) do
    "Optional PTC signature for return validation, e.g. '() -> {count :int}'. " <>
      "The '() ->' prefix is shorthand-optional — a bare type like '{count :int}' " <>
      "is equivalent and accepted. See docs/signature-syntax.md."
  end

  defp signature_description_for(:mcp_aggregator) do
    "Usually omit in aggregator mode. Do not pass for exploratory upstream calls. " <>
      "Only use when the user explicitly needs validated output and you know the exact " <>
      "PTC signature syntax, e.g. '() -> {count :int}'."
  end
end
