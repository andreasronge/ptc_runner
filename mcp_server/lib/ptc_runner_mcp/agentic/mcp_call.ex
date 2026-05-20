defmodule PtcRunnerMcp.Agentic.McpCall do
  @moduledoc """
  Agentic-only `tool/mcp-call` wrapper foundation.

  This module is deliberately separate from `PtcRunnerMcp.AggregatorTools`.
  The public `lisp_eval` adapter keeps its existing raw-value / `nil`
  world-fault semantics; `lisp_task` will consume this module later to expose
  tagged success and world-fault values to generated PTC-Lisp.
  """

  alias PtcRunner.Lisp.ExecutionError
  alias PtcRunnerMcp.Agentic.Ledger
  alias PtcRunnerMcp.{AggregatorConfig, Limits, McpResult, RawEnvelopePolicy, UpstreamCalls}
  alias PtcRunnerMcp.Upstream.Registry

  @allowed_keys %{
    "server" => :server,
    "tool" => :tool,
    "args" => :args,
    server: :server,
    tool: :tool,
    args: :args
  }

  @type normalized_args :: %{
          required(:server) => String.t(),
          required(:tool) => String.t(),
          required(:args) => map()
        }

  @doc """
  Builds a SubAgent tool map containing the agentic `"mcp-call"` closure.
  """
  @spec build(Ledger.t(), keyword()) :: map()
  def build(ledger, opts \\ []) when is_pid(ledger) and is_list(opts) do
    call_counter = Keyword.get_lazy(opts, :call_counter, fn -> :atomics.new(1, signed: false) end)

    opts =
      opts
      |> Keyword.put(:ledger, ledger)
      |> Keyword.put(:call_counter, call_counter)

    %{
      "mcp-call" => fn args -> call(args, opts) end
    }
  end

  @doc """
  Calls an upstream MCP tool and returns a tagged map visible to PTC-Lisp.

  Programmer faults raise `PtcRunner.Lisp.ExecutionError`. Upstream/world
  faults return `%{ok: false, reason: ..., message: ...}` and complete the
  ledger entry as `:error`.
  """
  @spec call(map(), keyword()) :: map()
  def call(args, opts) when is_map(args) and is_list(opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    turn = resolve_turn(Keyword.get(opts, :turn, 1))
    registry = Keyword.get(opts, :registry, Registry)

    %{server: server, tool: tool, args: call_args} = normalize_args!(args)

    check_configured!(registry, server)
    check_known_tool!(registry, server, tool)
    check_args_encodable!(server, tool, call_args)

    effect = registry |> cached_tool_schema(server, tool) |> classify_effect()
    id = Ledger.record_attempt(ledger, server, tool, call_args, effect, turn)
    started_at = System.monotonic_time(:millisecond)

    try do
      with :ok <- check_cap(opts) do
        dispatch(registry, server, tool, call_args, opts)
      end
      |> complete_and_tag(ledger, id, started_at)
    rescue
      e ->
        complete_wrapper_error(ledger, id, started_at, Exception.message(e))
        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        complete_wrapper_error(
          ledger,
          id,
          started_at,
          Exception.format(kind, reason, __STACKTRACE__)
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def call(args, _opts) do
    raise_programmer_fault("tool/mcp-call expects a map, got #{inspect_short(args)}")
  end

  defp resolve_turn(turn) when is_integer(turn) and turn > 0, do: turn

  defp resolve_turn(fun) when is_function(fun, 0) do
    case fun.() do
      turn when is_integer(turn) and turn > 0 -> turn
      _other -> 1
    end
  end

  defp resolve_turn(_other), do: 1

  @doc """
  Normalizes top-level `mcp-call` args.

  Accepts string or keyword/atom keys for `server`, `tool`, and `args`.
  Unknown keys and duplicated normalized keys are programmer faults reported
  as `{:error, message}`.
  """
  @spec normalize_args(map()) :: {:ok, normalized_args()} | {:error, String.t()}
  def normalize_args(args) when is_map(args) do
    with {:ok, normalized} <- normalize_top_level_keys(args),
         {:ok, server} <- fetch_required_string(normalized, :server, "server"),
         {:ok, tool} <- fetch_required_string(normalized, :tool, "tool"),
         {:ok, call_args} <- fetch_args_map(normalized, server, tool) do
      {:ok, %{server: server, tool: tool, args: call_args}}
    end
  end

  def normalize_args(args) do
    {:error, "tool/mcp-call expects a map, got #{inspect_short(args)}"}
  end

  @doc """
  Classifies an upstream tool effect using aggregator posture and annotations.
  """
  @spec classify_effect(map() | nil) :: Ledger.effect()
  def classify_effect(tool_schema) do
    if AggregatorConfig.read_only?() do
      :read
    else
      do_classify_effect(tool_schema)
    end
  end

  @doc "Builds the Lisp-facing tagged success value."
  @spec tagged_success(term()) :: map()
  def tagged_success(value), do: McpResult.success(value)

  @doc "Builds the Lisp-facing tagged world-fault value."
  @spec tagged_error(atom(), String.t()) :: map()
  def tagged_error(reason, message) when is_atom(reason) and is_binary(message),
    do: McpResult.error(reason, message)

  defp normalize_args!(args) do
    case normalize_args(args) do
      {:ok, normalized} -> normalized
      {:error, message} -> raise_programmer_fault(message)
    end
  end

  defp normalize_top_level_keys(args) do
    Enum.reduce_while(args, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Map.fetch(@allowed_keys, key) do
        {:ok, normalized_key} ->
          if Map.has_key?(acc, normalized_key) do
            {:halt, {:error, "tool/mcp-call got duplicate key #{inspect(normalized_key)}"}}
          else
            {:cont, {:ok, Map.put(acc, normalized_key, value)}}
          end

        :error ->
          {:halt, {:error, "tool/mcp-call got unknown key #{inspect(key)}"}}
      end
    end)
  end

  defp fetch_required_string(args, key, label) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      value ->
        {:error, "tool/mcp-call requires :#{label} (string), got #{inspect_short(value)}"}
    end
  end

  defp fetch_args_map(args, _server, _tool) do
    case Map.get(args, :args, %{}) do
      nil -> {:ok, %{}}
      value when is_map(value) -> {:ok, value}
      value -> {:error, "tool/mcp-call requires :args (map), got #{inspect_short(value)}"}
    end
  end

  defp do_classify_effect(nil), do: :unknown

  defp do_classify_effect(tool_schema) when is_map(tool_schema) do
    annotations = annotations(tool_schema)
    read_only? = truthy?(Map.get(annotations, "readOnlyHint"))
    destructive? = truthy?(Map.get(annotations, "destructiveHint"))

    cond do
      destructive? -> :write
      read_only? -> :read
      true -> :unknown
    end
  end

  defp annotations(%{annotations: annotations}) when is_map(annotations), do: annotations
  defp annotations(%{"annotations" => annotations}) when is_map(annotations), do: annotations
  defp annotations(annotations) when is_map(annotations), do: annotations

  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp check_configured!(registry, server) do
    if Registry.configured?(server, registry) do
      :ok
    else
      raise_programmer_fault("no upstream '#{server}' configured")
    end
  end

  defp check_known_tool!(registry, server, tool) do
    case Registry.cached_tools(server, registry) do
      nil ->
        :ok

      tools when is_list(tools) ->
        if tool_schema(tools, tool) do
          :ok
        else
          raise_programmer_fault("no tool '#{tool}' in upstream '#{server}'")
        end
    end
  end

  defp check_args_encodable!(server, tool, args) do
    case Jason.encode(args) do
      {:ok, _json} ->
        :ok

      {:error, reason} ->
        raise_programmer_fault(
          "tool '#{server}.#{tool}' rejected args: not JSON-encodable (#{inspect_short(reason)})"
        )
    end
  end

  defp dispatch(registry, server, tool, call_args, opts) do
    with {:ok, %{duration_ms: ensure_duration}} <- Registry.ensure_started(server, registry),
         :ok <- ensure_known_tool_post_start(registry, server, tool) do
      impl = Registry.lookup(server, registry).impl
      call_upstream(impl, server, tool, call_args, opts, ensure_duration)
    else
      {:error, reason, detail, %{duration_ms: duration}} ->
        # No upstream call was issued — no bytes received.
        {:world_fault, reason, detail, duration, nil}

      {:programmer_fault, message} ->
        raise_programmer_fault(message)
    end
  end

  defp ensure_known_tool_post_start(registry, server, tool) do
    case Registry.cached_tools(server, registry) do
      tools when is_list(tools) ->
        if tool_schema(tools, tool) do
          :ok
        else
          {:programmer_fault, "no tool '#{tool}' in upstream '#{server}'"}
        end

      nil ->
        :ok
    end
  end

  defp call_upstream(impl, server, tool, call_args, opts, ensure_duration) do
    timeout = Keyword.get(opts, :timeout, Limits.upstream_call_timeout_ms())

    max_response_bytes =
      Keyword.get(opts, :max_response_bytes, Limits.max_upstream_response_bytes())

    call_started_at = System.monotonic_time(:millisecond)

    result =
      impl.call(server, tool, call_args, timeout: timeout, max_response_bytes: max_response_bytes)

    call_duration = System.monotonic_time(:millisecond) - call_started_at
    total_duration = ensure_duration + call_duration

    case result do
      {:ok, %{"isError" => true} = value} ->
        # A tool-level error envelope: the JSON-RPC call succeeded, the
        # upstream signaled application failure. Per
        # `Plans/ptc-runner-mcp-payload-reduction.md` §4.1 these bytes
        # are NOT useful compression — they go into
        # `upstream_error_bytes` — but the program *did* receive the
        # full envelope, so we record its size (matching the
        # `lisp_eval` aggregator path).
        {:tool_error, server, tool, :tool_error, McpResult.tool_error_message(value),
         total_duration, result_bytes(value), value}

      {:ok, value} ->
        {:ok, server, tool, value, total_duration}

      {:error, reason, detail}
      when reason in [:upstream_unavailable, :upstream_error, :timeout, :response_too_large] ->
        # No (or only-partial) bytes received; not retained — `nil`.
        {:world_fault, reason, detail, total_duration, nil}

      other ->
        detail = "upstream impl returned malformed result: #{inspect(other, limit: 50)}"
        {:world_fault, :upstream_error, detail, total_duration, nil}
    end
  end

  defp check_cap(opts) do
    counter = Keyword.get_lazy(opts, :call_counter, fn -> :atomics.new(1, signed: false) end)
    max_calls = Keyword.get(opts, :max_calls, Limits.max_upstream_calls_per_program())
    slot = :atomics.add_get(counter, 1, 1)

    if slot <= max_calls do
      :ok
    else
      # Rejected without an attempt — no bytes received.
      {:world_fault, :cap_exhausted, "cap_exhausted", 0, nil}
    end
  end

  defp complete_and_tag({:ok, server, tool, value, duration}, ledger, id, _started_at) do
    {unwrapped_value, value_kind} = McpResult.unwrap(value)

    :ok =
      Ledger.complete_success(ledger, id,
        duration_ms: duration,
        result_bytes: result_bytes(value),
        result_overview: UpstreamCalls.result_overview(unwrapped_value, value_kind)
      )

    McpResult.success(value, raw?: RawEnvelopePolicy.enabled?(server, tool))
  end

  defp complete_and_tag(
         {:tool_error, server, tool, reason, detail, duration, result_bytes, envelope},
         ledger,
         id,
         _started_at
       ) do
    :ok =
      Ledger.complete_error(ledger, id, reason_string(reason), detail,
        duration_ms: duration,
        result_bytes: result_bytes,
        oversize: false
      )

    McpResult.error(reason, detail, envelope, raw?: RawEnvelopePolicy.enabled?(server, tool))
  end

  defp complete_and_tag(
         {:world_fault, reason, detail, duration, result_bytes},
         ledger,
         id,
         _started_at
       ) do
    # `Plans/ptc-runner-mcp-payload-reduction.md` §4.1: only the
    # `response_too_large` world-fault is `oversize`. `result_bytes` is
    # the encoded size for a tool-level `isError` envelope the program
    # actually received (counted into `upstream_error_bytes`), `nil`
    # for every world-fault where no full payload reached the program
    # (transport errors, oversize, cap, ensure-failed). `reason` is
    # always one of the `Upstream.reason/0` atoms (plus `:cap_exhausted`
    # and tool-level `:tool_error`).
    :ok =
      Ledger.complete_error(ledger, id, reason_string(reason), detail,
        duration_ms: duration,
        result_bytes: result_bytes,
        oversize: reason == :response_too_large
      )

    McpResult.error(reason, detail)
  end

  defp complete_wrapper_error(ledger, id, started_at, message) do
    duration = System.monotonic_time(:millisecond) - started_at
    :ok = Ledger.complete_error(ledger, id, "wrapper_error", message, duration_ms: duration)
  end

  defp cached_tool_schema(registry, server, tool) do
    case Registry.cached_tools(server, registry) do
      tools when is_list(tools) -> tool_schema(tools, tool)
      nil -> nil
    end
  end

  defp tool_schema(tools, tool) do
    Enum.find(tools, &(tool_name(&1) == tool))
  end

  defp tool_name(%{name: name}) when is_binary(name), do: name
  defp tool_name(%{"name" => name}) when is_binary(name), do: name
  defp tool_name(_), do: nil

  defp result_bytes(value) do
    case Jason.encode(value) do
      {:ok, json} -> byte_size(json)
      {:error, _} -> value |> inspect(limit: 50, printable_limit: 500) |> byte_size()
    end
  end

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp raise_programmer_fault(message) do
    raise ExecutionError, reason: :runtime_error, message: message
  end

  defp inspect_short(value), do: inspect(value, limit: 3, printable_limit: 40)
end
