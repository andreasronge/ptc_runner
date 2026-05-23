defmodule PtcRunnerMcp.AggregatorTools do
  @moduledoc """
  Builds the PTC-Lisp tools registry used in aggregator mode.

  The single tool registered today is `mcp-call`, callable as
  `(tool/mcp-call {:server "..." :tool "..." :args {...}})`. Per
  `Plans/ptc-runner-mcp-aggregator.md` §6.4 the closure captures
  the entire `call_context` map (collector pid, unique ref,
  `:counters`-backed cap, per-call timeout, byte cap) — not the
  process dictionary, not ETS — so `pmap` children incrementing in
  parallel observe the same counter without any shared mutable state.

  ## Error model (§7)

  Programmer-fault failures **raise** `PtcRunner.Lisp.ExecutionError`
  (the exception PTC-Lisp's tool executor reraises into the program's
  runtime error). World-fault failures return tagged
  `{:ok false, :reason reason, :message message}` data and record an
  `upstream_calls` entry via the collector.

    * `:server` value not in upstreams config → programmer-fault
      `runtime_error: no upstream '<name>' configured`.
    * Unknown tool on a started upstream (cache proof, §7.4) →
      programmer-fault `runtime_error: no tool '<tool>' in upstream '<server>'`.
    * Args missing / not JSON-encodable → programmer-fault
      `runtime_error: tool '<server>.<tool>' rejected args: <reason>`.
    * `ensure_started/1` failed → world-fault tagged error + `upstream_unavailable`.
    * Per-program cap hit → world-fault tagged error + `cap_exhausted`.
    * Upstream call returns error / timeout / oversized → world-fault
      tagged error + corresponding reason.
  """

  alias PtcRunner.Lisp.ExecutionError
  alias PtcRunnerMcp.{McpResult, RawEnvelopePolicy}
  alias PtcRunnerMcp.Upstream
  alias PtcRunnerMcp.Upstream.Registry
  alias PtcRunnerMcp.UpstreamCalls

  @tool_name "mcp-call"
  @allowed_arg_keys %{
    "server" => :server,
    "tool" => :tool,
    "args" => :args,
    server: :server,
    tool: :tool,
    args: :args
  }

  @doc """
  Builds the tools map for `Sandbox.execute(..., tools: ...)`.

  Returns `%{"mcp-call" => closure}`. The closure captures
  `call_context` (per §6.4) and `request_id` (for telemetry).

  Pass `registry: Upstream.Registry` (the default) or any other
  GenServer name in tests that spin up isolated registries.
  """
  @spec build(UpstreamCalls.call_context(), keyword()) :: map()
  def build(call_context, opts \\ []) when is_map(call_context) do
    registry = Keyword.get(opts, :registry, Registry)
    request_id = Keyword.get(opts, :request_id)

    %{
      @tool_name => mcp_call_closure(call_context, registry, request_id)
    }
  end

  # ----------------------------------------------------------------
  # Closure
  # ----------------------------------------------------------------

  defp mcp_call_closure(call_context, registry, request_id) do
    fn args when is_map(args) ->
      # Programmer-fault checks raise `ExecutionError`; the PTC-Lisp
      # tool executor reraises it into the program's runtime error
      # path, terminating the program (per §7.2).
      {server, tool, call_args} = validate_args(args, registry)
      check_configured(registry, server, tool)
      check_args_encodable(registry, server, tool, call_args)

      case check_cap(call_context, server, tool) do
        :proceed ->
          dispatch(call_context, registry, server, tool, call_args, request_id)

        :cap_exhausted ->
          McpResult.error(:cap_exhausted, "cap_exhausted")
      end
    end
  end

  # ----------------------------------------------------------------
  # Step 1: structural validation of (tool/mcp-call ...) args
  # ----------------------------------------------------------------

  defp validate_args(args, registry) do
    normalized = normalize_top_level_keys!(args)
    server = Map.get(normalized, :server)
    tool = Map.get(normalized, :tool)
    call_args = Map.get(normalized, :args)

    cond do
      not is_binary(server) or server == "" ->
        # No identification available — we don't have a valid server
        # name yet, so the message can't carry one. The catalog the
        # LLM sees in the tool description includes every configured
        # upstream name, so this is the recover-by-reading-the-catalog
        # path.
        raise_programmer_fault(
          "tool/mcp-call requires :server (string), got #{inspect_short(server)}" <>
            configured_servers_hint(registry)
        )

      not is_binary(tool) or tool == "" ->
        # §7.2: include the upstream name so the LLM can correlate
        # the error to a specific server entry in the catalog without
        # re-reading the program.
        raise_programmer_fault(
          "tool/mcp-call on upstream '#{server}' requires :tool (string), got #{inspect_short(tool)}" <>
            tool_discovery_hint(server)
        )

      is_nil(call_args) ->
        # Treat missing :args as empty map; this is the common case and
        # avoids forcing the LLM to pass `:args {}` when the tool takes
        # no arguments.
        {server, tool, %{}}

      not is_map(call_args) ->
        # §7.2: include `<server>.<tool>` so the LLM knows which call
        # site is wrong without consulting `upstream_calls` (which
        # never gets populated for programmer-fault failures that
        # short-circuit before any upstream call is attempted).
        raise_programmer_fault(
          "tool '#{server}.#{tool}' rejected args: :args must be a map, got #{inspect_short(call_args)}" <>
            describe_tool_hint(registry, server, tool)
        )

      true ->
        check_call_args_shape(registry, server, tool, call_args)
        {server, tool, call_args}
    end
  end

  defp normalize_top_level_keys!(args) do
    Enum.reduce(args, %{}, fn {key, value}, acc ->
      case Map.fetch(@allowed_arg_keys, key) do
        {:ok, normalized_key} ->
          if Map.has_key?(acc, normalized_key) do
            raise_programmer_fault("tool/mcp-call got duplicate key #{inspect(normalized_key)}")
          else
            Map.put(acc, normalized_key, value)
          end

        :error ->
          raise_programmer_fault("tool/mcp-call got unknown key #{inspect(key)}")
      end
    end)
  end

  # ----------------------------------------------------------------
  # Step 2: §7.2 / §7.4 classification
  # ----------------------------------------------------------------

  defp check_configured(registry, server, tool) do
    if Registry.configured?(server, registry) do
      check_known_tool(registry, server, tool)
    else
      raise_programmer_fault(
        "no upstream '#{server}' configured" <> configured_servers_hint(registry)
      )
    end
  end

  # §7.4: unknown tool on a *started* upstream is programmer-fault.
  # If the upstream isn't started, we cannot prove the tool is
  # absent — it routes through ensure_started below and surfaces
  # as a world-fault `upstream_unavailable` if that fails.
  defp check_known_tool(registry, server, tool) do
    case Registry.cached_tools(server, registry) do
      nil ->
        :ok

      tools when is_list(tools) ->
        if tool_known?(tools, tool) do
          :ok
        else
          raise_programmer_fault(
            "no tool '#{tool}' in upstream '#{server}'" <>
              known_tools_hint(server, tool, tools)
          )
        end
    end
  end

  defp tool_known?(tools, tool) do
    Enum.any?(tools, fn t -> tool_name_of(t) == tool end)
  end

  defp check_args_encodable(registry, server, tool, call_args) do
    case Jason.encode(call_args) do
      {:ok, _json} ->
        :ok

      {:error, reason} ->
        raise_programmer_fault(
          "tool '#{server}.#{tool}' rejected args: not JSON-encodable (#{inspect_short(reason)})" <>
            describe_tool_hint(registry, server, tool)
        )
    end
  end

  defp check_call_args_shape(registry, server, tool, call_args) do
    case find_cached_tool(registry, server, tool) do
      nil ->
        :ok

      cached_tool ->
        cached_tool
        |> tool_input_schema()
        |> reject_missing_required_with_unexpected_keys!(server, tool, call_args, registry)
    end
  end

  defp reject_missing_required_with_unexpected_keys!(schema, server, tool, call_args, registry)
       when is_map(schema) do
    properties = schema_properties(schema)
    required = schema_required(schema)

    if map_size(properties) > 0 and required != [] do
      supplied = call_args |> Map.keys() |> Enum.map(&to_string/1)
      missing = Enum.reject(required, &(&1 in supplied))
      unexpected = Enum.reject(supplied, &Map.has_key?(properties, &1))

      if missing != [] and unexpected != [] do
        raise_programmer_fault(
          "tool '#{server}.#{tool}' rejected args: received unexpected " <>
            pluralize("key", unexpected) <>
            " #{format_arg_names(unexpected)}; expected #{format_arg_names(Map.keys(properties))}. " <>
            "Missing required #{pluralize("arg", missing)} #{format_arg_names(missing)}." <>
            describe_tool_hint(registry, server, tool)
        )
      end
    end

    :ok
  end

  defp schema_properties(schema) do
    case Map.get(schema, "properties") || Map.get(schema, :properties) do
      properties when is_map(properties) ->
        Map.new(properties, fn {key, value} -> {to_string(key), value} end)

      _ ->
        %{}
    end
  end

  defp schema_required(schema) do
    case Map.get(schema, "required") || Map.get(schema, :required) do
      required when is_list(required) -> Enum.map(required, &to_string/1)
      _ -> []
    end
  end

  # ----------------------------------------------------------------
  # Step 3: per-program cap (closure-captured :counters)
  # ----------------------------------------------------------------

  defp check_cap(call_context, server, tool) do
    %{call_counter: counter, max_calls: max_calls} = call_context

    # §6.4 specifies :counters but :counters has no atomic
    # add-and-get; :atomics.add_get/3 is the right primitive. Spec
    # is being amended. Each caller atomically gets a unique slot
    # number; precise rejection means cap=1 with N concurrent
    # callers yields exactly 1 success + (N-1) cap_exhausted —
    # not the all-rejected case the bump-then-get pattern can
    # produce when reads land after concurrent bumps.
    slot = :atomics.add_get(counter, 1, 1)

    if slot <= max_calls do
      :proceed
    else
      entry = UpstreamCalls.error_entry(server, tool, :cap_exhausted, "cap_exhausted", 0)
      UpstreamCalls.record(call_context, entry)
      :cap_exhausted
    end
  end

  # ----------------------------------------------------------------
  # Step 4: ensure_started → call → record
  # ----------------------------------------------------------------

  defp dispatch(call_context, registry, server, tool, call_args, request_id) do
    telemetry_meta = %{
      request_id: request_id,
      server: server,
      tool: tool,
      caller: :mcp,
      profile: :mcp_aggregator
    }

    # `do_dispatch/5` returns a 4-tuple — `{:ok, value, durations}` /
    # `{:world_fault, reason, detail, durations}`.
    # The durations map carries `ensure_duration_ms` (cold-start
    # spawn + handshake) and `call_duration_ms` (steady-state
    # `tools/call` round-trip) decomposed per spec §16. Operators
    # subscribe to the `[:upstream, :call, :stop]` event and read
    # both fields off the metadata to attribute cold-start vs
    # steady-state cost; programs see tagged `McpResult` data.
    :telemetry.span([:ptc_lisp, :upstream, :call], telemetry_meta, fn ->
      result = do_dispatch(call_context, registry, server, tool, call_args)
      {result, stop_meta(telemetry_meta, result)}
    end)
    |> tag_for_program(server, tool)
  end

  defp do_dispatch(call_context, registry, server, tool, call_args) do
    # §4.3 first bullet: "no automatic retry of `ensure_started/1`
    # within a single program; the next program is a fresh attempt."
    # The failure cache lives in `call_context` (an ETS table owned
    # by the request worker, auto-cleaned on worker death). The
    # registry itself does NOT cache failures across programs — a
    # transient startup failure cannot poison subsequent
    # `tools/call` requests.
    case UpstreamCalls.cached_failure(call_context, server) do
      {:cached, reason, detail} ->
        # Per §8.5 "`upstream_unavailable` during recovery/backoff
        # window with no attempt made → 0": no fresh attempt was
        # made for this entry, so duration is 0. Both telemetry
        # components are zero for the same reason — we neither
        # spawned the upstream nor issued a `tools/call`.
        entry = UpstreamCalls.error_entry(server, tool, reason, detail, 0)
        UpstreamCalls.record(call_context, entry)
        {:world_fault, reason, detail, zero_durations()}

      :miss ->
        attempt_dispatch(call_context, registry, server, tool, call_args)
    end
  end

  defp zero_durations, do: %{ensure_duration_ms: 0, call_duration_ms: 0}

  defp attempt_dispatch(call_context, registry, server, tool, call_args) do
    # §4.3 first bullet "no automatic retry of `ensure_started/1`
    # within a single program" — under `pmap` N concurrent branches
    # all see `cached_failure/2 → :miss` at once and would each run
    # a real `ensure_started/2`. Even though the registry serializes
    # per-name, that's still N attempts within one program. The
    # leader/follower ETS lock ensures exactly **one** caller (the
    # leader) runs `Registry.ensure_started/2`; followers wait on
    # the leader's published result via `await_ensure_result/3`.
    case UpstreamCalls.acquire_ensure_lock(call_context, server) do
      :leader ->
        attempt_dispatch_as_leader(call_context, registry, server, tool, call_args)

      :follower ->
        attempt_dispatch_as_follower(call_context, registry, server, tool, call_args)
    end
  end

  defp attempt_dispatch_as_leader(call_context, registry, server, tool, call_args) do
    ensure_at = System.monotonic_time(:millisecond)

    case Registry.ensure_started(server, registry) do
      {:ok, %{duration_ms: ensure_duration}} ->
        :ok = UpstreamCalls.publish_ensure_result(call_context, server, :ok)

        complete_dispatch_after_ensure(
          call_context,
          registry,
          server,
          tool,
          call_args,
          ensure_duration
        )

      {:error, reason, detail, %{duration_ms: ensure_duration}} ->
        # Mark failure first so `cached_failure/2` short-circuits
        # any subsequent calls in this program (the leader and
        # followers both publish/record their entry below).
        :ok = UpstreamCalls.mark_failure(call_context, server, reason, detail)
        :ok = UpstreamCalls.publish_ensure_result(call_context, server, {:error, reason, detail})

        duration =
          if ensure_duration > 0,
            do: ensure_duration,
            else: System.monotonic_time(:millisecond) - ensure_at

        entry = UpstreamCalls.error_entry(server, tool, reason, detail, duration)
        UpstreamCalls.record(call_context, entry)
        # Telemetry decomposition: ensure_duration is the wall-clock
        # the leader paid attempting to spawn/handshake the upstream;
        # call_duration is 0 because we never reached `tools/call`.
        {:world_fault, reason, detail, %{ensure_duration_ms: duration, call_duration_ms: 0}}
    end
  end

  defp attempt_dispatch_as_follower(call_context, registry, server, tool, call_args) do
    timeout_ms = call_context.call_timeout_ms

    case UpstreamCalls.await_ensure_result(call_context, server, timeout_ms) do
      :ok ->
        # Leader's ensure_started succeeded — proceed to call. The
        # leader paid the wall-clock for the spawn; followers have
        # `duration_ms = 0` for the ensure-started portion (no
        # fresh attempt) and only the call's own duration counts
        # in their entry per §8.5.
        complete_dispatch_after_ensure(call_context, registry, server, tool, call_args, 0)

      {:error, reason, detail} ->
        # Leader's ensure_started failed (or follower timed out
        # waiting). Followers have `duration_ms: 0` per §8.5
        # ("upstream_unavailable during recovery/backoff window
        # with no attempt made → 0"). Both telemetry components
        # are zero — followers paid no spawn cost (the leader did)
        # and never issued a `tools/call` of their own.
        entry = UpstreamCalls.error_entry(server, tool, reason, detail, 0)
        UpstreamCalls.record(call_context, entry)
        {:world_fault, reason, detail, zero_durations()}
    end
  end

  defp complete_dispatch_after_ensure(
         call_context,
         registry,
         server,
         tool,
         call_args,
         ensure_duration
       ) do
    # §7.4 cold-start path: the cache check in `check_known_tool/3`
    # ran BEFORE `ensure_started/2`, when the upstream wasn't yet
    # started and `cached_tools/2` returned `nil` (we couldn't
    # prove tool absence). Now that the upstream is started, the
    # tools/list cache is populated — re-check authoritatively.
    # If the tool is genuinely absent, raise programmer-fault per
    # §7.4 ("`<server>` is in `started_upstreams` AND `<server>`'s
    # cached `tools/list` lacks `<tool>`"). Crucially this raise
    # happens BEFORE `Upstream.call/4` — no entry is recorded for
    # an unattempted call (matches §7.2 last sentence: entries
    # are recorded only "if an upstream call was actually attempted").
    ensure_known_tool_post_start!(registry, server, tool)
    impl = Registry.lookup(server, registry).impl
    invoke_call(call_context, impl, server, tool, call_args, ensure_duration)
  end

  # Post-`ensure_started/2` programmer-fault check (§7.4). Distinct
  # from the pre-`ensure_started` `check_known_tool/3` because that
  # one runs against a possibly-empty cache (cold start) and falls
  # through; this one runs against the freshly-populated cache and
  # is the authoritative classifier. The two checks together cover
  # both branches of §7.4: warm-cache absent → raise (handled by
  # `check_known_tool/3` in step 2); cold start → ensure_started
  # success → cache populated → check here.
  #
  # Bang-style: raises `ExecutionError` (programmer-fault) when the
  # tool is genuinely absent. The `nil` cached-tools path is a
  # `:DOWN` race (the upstream went unhealthy between
  # `ensure_started/2` returning :ok and our lookup) — we cannot
  # prove the tool's absence in that window, so we fall through to
  # the call path; the upstream call will surface a world-fault
  # `:upstream_unavailable` from `Fake.call/4` / `Fake.list_tools`
  # routing failure.
  defp ensure_known_tool_post_start!(registry, server, tool) do
    case Registry.cached_tools(server, registry) do
      tools when is_list(tools) ->
        if tool_known?(tools, tool) do
          :ok
        else
          raise_programmer_fault(
            "no tool '#{tool}' in upstream '#{server}'" <>
              known_tools_hint(server, tool, tools)
          )
        end

      nil ->
        # Race: a `:DOWN` invalidated the entry between the
        # `ensure_started/2` success return and this lookup.
        # Cannot prove tool absence — let the call path surface
        # the resulting world-fault.
        :ok
    end
  end

  defp invoke_call(call_context, impl, server, tool, call_args, ensure_duration) do
    %{
      call_timeout_ms: timeout_ms,
      max_response_bytes: max_bytes
    } = call_context

    call_at = System.monotonic_time(:millisecond)

    result =
      impl.call(server, tool, call_args, timeout: timeout_ms, max_response_bytes: max_bytes)

    call_duration = System.monotonic_time(:millisecond) - call_at

    # Per §8.5 the entry's `duration_ms` is "time spent attempting
    # the operation," **including ensure-started overhead the
    # caller paid for**. The leader paid for the spawn + handshake;
    # followers see `ensure_duration = 0` because `ensure_started`
    # short-circuited via the lock for them. Either way the user-
    # visible total is `ensure + call`. Operators who need to
    # decompose the two components subscribe to the
    # `[:ptc_lisp, :upstream, :call, :*]` telemetry events
    # which carry both fields separately.
    total_duration = ensure_duration + call_duration
    durations = %{ensure_duration_ms: ensure_duration, call_duration_ms: call_duration}

    case result do
      {:ok, value} ->
        # `Plans/ptc-runner-mcp-payload-reduction.md` §4.1 / §7: record
        # the upstream response size **as received** — measured on the
        # raw `value` here, before `maybe_auto_decode/3` mutates it,
        # before any `--trace-payloads` redaction downstream, and
        # before any envelope size cap. This is the byte size a no-PTC
        # client would have seen.
        result_bytes = response_bytes(value)

        # Phase 4 hardening (Plans/ptc-runner-mcp-aggregator.md §16
        # entry 2): an upstream `tools/call` that returns
        # `{:ok, %{"isError" => true, ...}}` is a *tool-level* error
        # — the JSON-RPC call itself succeeded, but the upstream
        # signaled application failure inside the result envelope.
        # Per §7.1 this is a world-fault: programs see tagged
        # `:tool_error` data, and `upstream_calls` records
        # `status: "error"`, `reason: "tool_error"`. The bounded
        # detail is extracted from `content[0].text` when shaped that
        # way (the MCP convention for human-readable error messages);
        # otherwise we inspect the value as a fallback.
        #
        # The check runs before value unwrapping so an `isError: true`
        # envelope cannot be mistaken for a successful text payload.
        case classify_value(value) do
          :tool_error ->
            detail = McpResult.tool_error_message(value)

            # A tool-level error envelope's bytes are NOT useful
            # compression (§4.1) — they go into `upstream_error_bytes`,
            # so we still record the size for diagnostics but the entry
            # is `status: "error"`.
            entry =
              UpstreamCalls.error_entry(server, tool, :tool_error, detail, total_duration,
                result_bytes: result_bytes
              )

            UpstreamCalls.record(call_context, entry)
            {:world_fault, :tool_error, detail, durations, value}

          :ok ->
            {unwrapped_value, value_kind} = McpResult.unwrap(value)

            # Pipeline ordering (Plans/json-support.md §6.4 — single
            # source of truth):
            #
            #   classify_value (above) → auto-decode telemetry → tagged unwrap
            #
            # Auto-decode runs HERE — after classify_value short-
            # circuits world-faults (so `isError: true` envelopes never
            # reach this branch and never trigger a spurious
            # `:auto_decode` telemetry event), and before tagged
            # unwrapping (so promotion operates on the upstream's
            # original map). The maybe_auto_decode/3 helper preserves
            # the original `content[]` and only adds `structuredContent`
            # when all four §6.1 preconditions hold.
            _promoted_for_telemetry = maybe_auto_decode(value, server, tool)

            entry =
              UpstreamCalls.success_entry(server, tool, total_duration,
                result_bytes: result_bytes,
                result_overview: UpstreamCalls.result_overview(unwrapped_value, value_kind)
              )

            UpstreamCalls.record(call_context, entry)
            {:ok, value, durations}
        end

      {:error, reason, detail}
      when reason in [:upstream_unavailable, :upstream_error, :timeout, :response_too_large] ->
        # `:response_too_large` → `oversize: true` (set by
        # `error_entry/6` from the reason). `result_bytes` is left
        # `nil`: the overflow paths abort without retaining an exact
        # count, and `Plans/ptc-runner-mcp-payload-reduction.md` §4.1
        # forbids parsing the human-readable detail string to recover
        # one. The same applies to the other world-faults — no partial
        # byte count is retained, so `result_bytes` is `nil`.
        entry = UpstreamCalls.error_entry(server, tool, reason, detail, total_duration)
        UpstreamCalls.record(call_context, entry)
        {:world_fault, reason, detail, durations}

      other ->
        # Defensive fallback: a buggy impl that returns a non-conformant
        # tuple should still produce a world-fault entry so the program
        # observes `nil` (not a crash) and the calling LLM sees a
        # diagnostic in `upstream_calls`.
        detail = "upstream impl returned malformed result: #{inspect(other, limit: 50)}"
        entry = UpstreamCalls.error_entry(server, tool, :upstream_error, detail, total_duration)
        UpstreamCalls.record(call_context, entry)
        {:world_fault, :upstream_error, detail, durations}
    end
  end

  # Byte size of an upstream response payload, measured the way a
  # no-PTC client would have observed it: `byte_size(Jason.encode!/1)`.
  # The value has already passed the upstream impl's
  # `:max_response_bytes` check, so this is bounded. A re-encode
  # failure (vanishingly rare for already-decoded JSON) collapses to
  # `nil` rather than crashing the program — the metric is best-effort
  # accounting, not a correctness invariant.
  defp response_bytes(value) do
    case Jason.encode(value) do
      {:ok, json} -> byte_size(json)
      {:error, _} -> nil
    end
  end

  defp tag_for_program({:ok, value, _durations}, server, tool) do
    McpResult.success(value, raw?: RawEnvelopePolicy.enabled?(server, tool))
  end

  defp tag_for_program({:world_fault, reason, detail, _durations}, server, tool) do
    detail = maybe_append_world_fault_hint(reason, detail, server, tool)
    McpResult.error(reason, detail)
  end

  defp tag_for_program({:world_fault, reason, detail, _durations, envelope}, server, tool) do
    detail = maybe_append_world_fault_hint(reason, detail, server, tool)
    McpResult.error(reason, detail, envelope, raw?: RawEnvelopePolicy.enabled?(server, tool))
  end

  defp maybe_append_world_fault_hint(:tool_error, detail, server, tool),
    do: detail <> describe_tool_hint(Registry, server, tool)

  defp maybe_append_world_fault_hint(_reason, detail, _server, _tool), do: detail

  defp stop_meta(meta, {:ok, _value, durations}) do
    meta
    |> Map.put(:status, :ok)
    |> Map.merge(durations)
  end

  defp stop_meta(meta, {:world_fault, reason, _detail, durations}) do
    meta
    |> Map.put(:status, :error)
    |> Map.put(:reason, reason)
    |> Map.merge(durations)
  end

  defp stop_meta(meta, {:world_fault, reason, _detail, durations, _envelope}) do
    meta
    |> Map.put(:status, :error)
    |> Map.put(:reason, reason)
    |> Map.merge(durations)
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp configured_servers_hint(registry) do
    case configured_server_names(registry) do
      [] ->
        "\nHint: use (mcp/servers) to inspect configured upstreams."

      names ->
        "\nConfigured upstreams: #{Enum.join(Enum.take(names, 8), ", ")}." <>
          "\nHint: use (mcp/servers) or (apropos \"query\" {:limit 8})."
    end
  end

  defp tool_discovery_hint(server) do
    server_ref = lisp_string(server)

    "\nHint: use (dir #{server_ref} {:limit 20}) or " <>
      "(apropos \"query\" {:limit 8}); then use " <>
      "(doc #{tool_ref(server, "tool")}) for required args and a call example."
  end

  defp describe_tool_hint(registry, server, tool) do
    summary =
      case find_cached_tool(registry, server, tool) do
        nil -> ""
        cached_tool -> tool_summary_hint(cached_tool)
      end

    summary <>
      "\nHint: use (doc #{tool_ref(server, tool)}) for required args and a call example."
  end

  defp known_tools_hint(server, attempted_tool, tools) do
    names =
      tools
      |> Enum.map(&tool_name_of/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    known =
      case Enum.take(names, 8) do
        [] -> ""
        shown -> "\nKnown tools include: #{Enum.join(shown, ", ")}."
      end

    did_you_mean =
      case closest_tool_name(attempted_tool, names) do
        nil ->
          ""

        candidate ->
          "\nDid you mean \"#{candidate}\"? Use (doc #{tool_ref(server, candidate)})."
      end

    known <> did_you_mean <> tool_discovery_hint(server)
  end

  defp tool_ref(server, tool), do: lisp_string("#{server}/#{tool}")

  defp lisp_string(value) when is_binary(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _} -> inspect(value)
    end
  end

  defp configured_server_names(registry) do
    registry
    |> GenServer.call(:all_routings)
    |> Map.keys()
    |> Enum.sort()
  catch
    :exit, _ -> []
  end

  defp find_cached_tool(registry, server, tool) do
    case Registry.cached_tools(server, registry) do
      tools when is_list(tools) -> Enum.find(tools, &(tool_name_of(&1) == tool))
      _ -> nil
    end
  end

  defp tool_summary_hint(tool) do
    case tool_description_of(tool) do
      nil -> ""
      "" -> ""
      description -> "\nTool summary: #{truncate(description, 180)}"
    end
  end

  defp closest_tool_name(_attempted_tool, []), do: nil

  defp closest_tool_name(attempted_tool, names) when is_binary(attempted_tool) do
    {candidate, score} =
      names
      |> Enum.map(&{&1, String.jaro_distance(attempted_tool, &1)})
      |> Enum.max_by(fn {_name, score} -> score end, fn -> {nil, 0.0} end)

    if score >= 0.82, do: candidate
  end

  defp pluralize(word, [_one]), do: word
  defp pluralize(word, _many), do: word <> "s"

  defp format_arg_names(names) do
    names
    |> Enum.sort()
    |> Enum.map_join(", ", &format_arg_name/1)
  end

  defp format_arg_name(name) do
    name = to_string(name)
    lisp_name = String.replace(name, "_", "-")

    if lisp_name == name do
      ":" <> name
    else
      ":#{lisp_name} (encoded as :#{name})"
    end
  end

  # Phase 4 hardening: classify a successful upstream payload. A
  # map whose `"isError"` key is `true` is a tool-level failure
  # (§16 entry 2 / amended §7.1) and surfaces as a world-fault.
  # Everything else is a plain success.
  defp classify_value(%{"isError" => true}), do: :tool_error
  defp classify_value(_), do: :ok

  # Plans/json-support.md §6 auto-decode promotion. Pure shape
  # inspector + telemetry emitter — adds `structuredContent` to a
  # well-formed JSON-as-text upstream envelope and leaves everything
  # else untouched. Telemetry fires per §7's per-outcome table:
  #
  #   :promoted          — all four §6.1 conditions held; envelope
  #                        gets `structuredContent` added (with the
  #                        decoded-bare-nil → :"json-null" §6.4
  #                        sub-field substitution).
  #   :already_structured — `structuredContent` was already present
  #                        and non-nil; promotion skipped.
  #   :decode_failed     — mimeType matched but `Jason.decode/1`
  #                        rejected the text; envelope passes through
  #                        unchanged. Per §6.4 / §8: NO `upstream_calls`
  #                        entry is added — the side-channel is
  #                        reserved for world-faults, not soft decode
  #                        misses.
  #
  # No telemetry event is emitted when the envelope is not a map,
  # has no first text-content item, or has a non-matching mimeType
  # (§7 last paragraph: "the volume would dwarf the signal").
  defp maybe_auto_decode(value, server, tool) when is_map(value) do
    case extract_first_text_item(value) do
      {:ok, text, mime_type} ->
        cond do
          not json_mime?(mime_type) ->
            value

          structured_content_present?(value) ->
            emit_auto_decode_telemetry(:already_structured, server, tool, mime_type, %{
              decoded_bytes: 0
            })

            value

          true ->
            attempt_decode(value, text, server, tool, mime_type)
        end

      :no_text_item ->
        value
    end
  end

  defp maybe_auto_decode(value, _server, _tool), do: value

  # Returns `{:ok, text, mime_type}` when the upstream envelope's
  # `content[0]` is a text item (`type == "text"` and `text` is a
  # binary; `mimeType` may be nil/absent and is checked against the
  # JSON-mime allowlist by `json_mime?/1`). Returns `:no_text_item`
  # otherwise — including for empty content lists, non-list content
  # values, and non-text first items (e.g. image / resource items
  # that happen to carry `mimeType: "application/json"`).
  defp extract_first_text_item(%{"content" => [first | _]}) when is_map(first) do
    case first do
      %{"type" => "text", "text" => text} when is_binary(text) ->
        {:ok, text, Map.get(first, "mimeType")}

      _ ->
        :no_text_item
    end
  end

  defp extract_first_text_item(_), do: :no_text_item

  # §6.1 condition 3: exact `application/json` OR any string ending
  # in `+json` (RFC 6839 structured suffix — covers
  # `application/ld+json`, `application/vnd.foo+json`, etc.). The
  # suffix check is intentionally permissive: any binary ending in
  # `+json` qualifies, no slash-before requirement, per §6.1's
  # exact wording "any string ending in `+json`".
  defp json_mime?("application/json"), do: true
  defp json_mime?(mime) when is_binary(mime), do: String.ends_with?(mime, "+json")
  defp json_mime?(_), do: false

  # §6.1 condition 1: "absent or nil" — both treat as eligible for
  # promotion. A non-nil `structuredContent` already supplied by the
  # upstream wins and is never overridden.
  defp structured_content_present?(value) do
    case Map.fetch(value, "structuredContent") do
      {:ok, nil} -> false
      {:ok, _} -> true
      :error -> false
    end
  end

  # §6.4: `Jason.decode/1` MUST NOT raise. Wrap explicitly — the
  # return tuple is the entire surface. On `{:error, _}` the result
  # passes through unchanged AND no `upstream_calls` entry is added
  # (§6.4 / §8 side-channel invariant lock-in). The `:decode_failed`
  # telemetry event is the only operator-visible signal.
  defp attempt_decode(value, text, server, tool, mime_type) do
    case Jason.decode(text) do
      {:ok, decoded} ->
        # §6.4 sub-field rule: a decoded bare `nil` (the JSON literal
        # `"null"`) is substituted with `:"json-null"` so the field
        # is distinguishable from "absent". The substitution applies
        # ONLY to bare `nil` — `false`, `0`, `""`, `[]` are
        # legitimate JSON payloads and promote verbatim per the
        # post-§5.2 carve-out (commit 6852ca4).
        sub_value = if is_nil(decoded), do: :"json-null", else: decoded
        promoted = Map.put(value, "structuredContent", sub_value)

        emit_auto_decode_telemetry(
          :promoted,
          server,
          tool,
          mime_type,
          promoted_measurements(decoded)
        )

        promoted

      {:error, _reason} ->
        emit_auto_decode_telemetry(:decode_failed, server, tool, mime_type, %{
          decoded_bytes: 0,
          text_bytes: byte_size(text)
        })

        value
    end
  end

  # Per §7's measurement table, `:promoted` reports the byte size of
  # `Jason.encode!(value)` on the promoted value. Best-effort: a
  # round-trip encode failure (e.g. an exotic decoded structure that
  # can't re-serialize cleanly — vanishingly rare for Jason output)
  # suppresses the field but does NOT suppress the event itself.
  defp promoted_measurements(decoded) do
    case Jason.encode(decoded) do
      {:ok, encoded} -> %{decoded_bytes: byte_size(encoded)}
      {:error, _} -> %{}
    end
  end

  defp emit_auto_decode_telemetry(outcome, server, tool, mime_type, measurements) do
    metadata = %{
      server: server,
      tool: tool,
      mime_type: mime_type,
      outcome: outcome
    }

    :telemetry.execute(
      [:ptc_lisp, :upstream, :auto_decode, :stop],
      measurements,
      metadata
    )
  end

  defp tool_name_of(%{name: n}) when is_binary(n), do: n
  defp tool_name_of(%{"name" => n}) when is_binary(n), do: n
  defp tool_name_of(_), do: nil

  defp tool_input_schema(%{input_schema: schema}) when is_map(schema), do: schema
  defp tool_input_schema(%{"input_schema" => schema}) when is_map(schema), do: schema
  defp tool_input_schema(%{"inputSchema" => schema}) when is_map(schema), do: schema
  defp tool_input_schema(_), do: %{}

  defp tool_description_of(%{description: d}) when is_binary(d), do: d
  defp tool_description_of(%{"description" => d}) when is_binary(d), do: d
  defp tool_description_of(_), do: nil

  defp truncate(text, max_length) when is_binary(text) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length) <> "..."
    else
      text
    end
  end

  defp raise_programmer_fault(message) do
    raise ExecutionError, reason: :runtime_error, message: message
  end

  defp inspect_short(value), do: inspect(value, limit: 3, printable_limit: 40)

  @doc false
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @doc """
  Returns the `Upstream` behaviour module type used for `impl` lookups.
  Public for documentation; not actually called at runtime.
  """
  @spec upstream_behaviour() :: module()
  def upstream_behaviour, do: Upstream
end
