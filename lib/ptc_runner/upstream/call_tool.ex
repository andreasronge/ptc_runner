defmodule PtcRunner.Upstream.CallTool do
  @moduledoc false

  alias PtcRunner.Lisp.ExecutionError
  alias PtcRunner.Upstream.{Result, RunContext, Runtime}

  @allowed_arg_keys %{
    "server" => :server,
    "tool" => :tool,
    "args" => :args,
    server: :server,
    tool: :tool,
    args: :args
  }

  @spec build(RunContext.t()) :: map()
  def build(%RunContext{} = context) do
    %{"call" => fn args -> call(context, args) end}
  end

  defp call(%RunContext{} = context, args) do
    case RunContext.ensure_open(context) do
      :ok -> call_open(context, args)
      {:error, :run_context_closed} -> Result.error(:run_context_closed, "run_context_closed")
    end
  end

  defp call_open(%RunContext{} = context, args) when is_map(args) do
    {server, tool, call_args} = validate_args!(args, context)
    check_configured!(context, server, tool)
    check_args_encodable!(server, tool, call_args)
    check_cached_schema!(context, server, tool, call_args)

    case RunContext.check_call_cap(context, server, tool) do
      :proceed -> dispatch(context, server, tool, call_args)
      :cap_exhausted -> Result.error(:cap_exhausted, "cap_exhausted")
    end
  end

  defp call_open(_context, other) do
    raise_fault!("tool/call requires a map, got #{inspect(other)}")
  end

  defp validate_args!(args, context) do
    normalized =
      Enum.reduce(args, %{}, fn {key, value}, acc ->
        case Map.fetch(@allowed_arg_keys, key) do
          {:ok, normalized_key} ->
            if Map.has_key?(acc, normalized_key) do
              raise_fault!("tool/call got duplicate key #{inspect(normalized_key)}")
            else
              Map.put(acc, normalized_key, value)
            end

          :error ->
            raise_fault!("tool/call got unknown key #{inspect(key)}")
        end
      end)

    server = Map.get(normalized, :server)
    tool = Map.get(normalized, :tool)
    call_args = Map.get(normalized, :args, %{})

    cond do
      not is_binary(server) or server == "" ->
        raise_fault!(
          "tool/call requires :server (string), got #{inspect(server)}. Configured upstreams: #{Enum.join(Runtime.upstream_names(context.runtime), ", ")}"
        )

      not is_binary(tool) or tool == "" ->
        raise_fault!(
          "tool/call on upstream '#{server}' requires :tool (string), got #{inspect(tool)}"
        )

      not is_map(call_args) ->
        raise_fault!(
          "tool '#{server}.#{tool}' rejected args: :args must be a map, got #{inspect(call_args)}"
        )

      true ->
        {server, tool, call_args}
    end
  end

  defp check_configured!(context, server, tool) do
    case Runtime.upstream(context.runtime, server) do
      nil ->
        raise_fault!(
          "no upstream '#{server}' configured. Configured upstreams: #{Enum.join(Runtime.upstream_names(context.runtime), ", ")}"
        )

      upstream ->
        if is_nil(upstream.tools) or Enum.any?(upstream.tools, &(Map.get(&1, "name") == tool)) do
          :ok
        else
          known =
            upstream.tools |> Enum.map(&Map.get(&1, "name")) |> Enum.sort() |> Enum.join(", ")

          raise_fault!("no tool '#{tool}' in upstream '#{server}'. Known tools: #{known}")
        end
    end
  end

  defp check_args_encodable!(server, tool, call_args) do
    case Jason.encode(call_args) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        raise_fault!(
          "tool '#{server}.#{tool}' rejected args: not JSON-encodable (#{inspect(reason)})"
        )
    end
  end

  defp check_cached_schema!(context, server, tool, call_args) do
    upstream = Runtime.upstream(context.runtime, server)
    cached_tool = Enum.find(upstream.tools || [], &(Map.get(&1, "name") == tool))
    schema = (cached_tool && cached_tool["inputSchema"]) || %{}
    required = Map.get(schema, "required", []) |> Enum.map(&to_string/1)
    supplied = call_args |> Map.keys() |> Enum.map(&to_string/1)
    missing = Enum.reject(required, &(&1 in supplied))

    if missing == [] do
      :ok
    else
      raise_fault!(
        "tool '#{server}.#{tool}' rejected args: missing required args #{Enum.join(missing, ", ")}"
      )
    end
  end

  defp dispatch(context, server, tool, call_args) do
    started_at = System.monotonic_time(:millisecond)

    opts = [
      timeout: context.limits.call_timeout_ms,
      max_response_bytes: context.limits.max_response_bytes
    ]

    case Runtime.call_tool(context.runtime, server, tool, call_args, opts) do
      {:ok, value} ->
        duration = System.monotonic_time(:millisecond) - started_at
        value_kind = Result.value_kind(value)

        overview =
          context.runtime
          |> Runtime.scrub(value)
          |> Result.result_overview(value_kind)

        RunContext.record(
          context,
          RunContext.success_entry(server, tool, duration,
            result_bytes: safe_size(value),
            result_overview: overview
          )
        )

        Result.success(value)

      {:error, reason, detail} ->
        duration = System.monotonic_time(:millisecond) - started_at
        scrubbed_detail = Runtime.scrub(context.runtime, detail)

        RunContext.record(
          context,
          RunContext.error_entry(server, tool, reason, scrubbed_detail, duration)
        )

        Result.error(reason, scrubbed_detail)
    end
  end

  defp safe_size(value) do
    :erlang.external_size(value)
  rescue
    _ -> nil
  end

  defp raise_fault!(message) do
    raise ExecutionError, reason: :runtime_error, message: message
  end
end
