defmodule PtcRunner.Kernel.RuntimeTools do
  @moduledoc """
  Internal construction of reserved runtime capabilities.

  Both environments receive read-only usage and local capability discovery.
  Only the workflow receives the annotation route. Every route is instrumented
  with the same canonical capability start/stop events.
  """

  alias PtcRunner.Kernel.Environment
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Lisp.RetainedSize

  @doc "Builds the reserved runtime-tool map for one environment."
  def tools(state, environment, event_sink, kind) when kind in [:workflow, :mission] do
    %{
      "runtime-usage" => fn arguments -> usage(state, arguments) end,
      "runtime-remaining" => fn arguments -> remaining(state, arguments) end,
      "cap-list" => fn arguments -> capability_list(state, environment, arguments) end,
      "cap-describe" => fn arguments -> capability_description(state, environment, arguments) end
    }
    |> maybe_put_annotation(state, event_sink, kind)
    |> Map.new(fn {name, callback} ->
      {name, instrument(state, event_sink, kind, name, callback)}
    end)
  end

  @doc "Wraps an internal runtime callback with canonical capability events."
  def instrument(state, event_sink, environment, name, callback)
      when environment in [:workflow, :mission] and is_binary(name) and is_function(callback, 1) do
    fn arguments ->
      capability_id = Events.id("capability")
      started_ms = System.monotonic_time(:millisecond)

      case Events.emit(state, event_sink, "capability-started", %{
             capability_id: capability_id,
             environment: environment,
             name: name
           }) do
        :ok ->
          result = callback.(arguments)

          _ =
            Events.emit(state, event_sink, "capability-stopped", %{
              capability_id: capability_id,
              environment: environment,
              name: name,
              status: result_status(result),
              duration_ms: Events.duration_ms(started_ms)
            })

          result

        {:error, :event_sink_error} ->
          %{status: :error, kind: :event_sink_error, reason: :event_sink_error}
      end
    end
  end

  defp usage(state, arguments) when is_map(arguments) and map_size(arguments) == 0,
    do: RunState.usage(state)

  defp usage(state, _arguments), do: protocol_error(state, :invalid_runtime_usage_request)

  defp remaining(state, arguments) when is_map(arguments) and map_size(arguments) == 0,
    do: RunState.remaining_ms(state)

  defp remaining(state, _arguments), do: protocol_error(state, :invalid_runtime_remaining_request)

  defp capability_list(_state, environment, arguments)
       when is_map(arguments) and map_size(arguments) == 0,
       do: Environment.metadata(environment)

  defp capability_list(state, _environment, _arguments),
    do: protocol_error(state, :invalid_capability_list_request)

  defp capability_description(_state, environment, %{"name" => name}) when is_binary(name) do
    Enum.find(Environment.metadata(environment), &(&1.name == name))
  end

  defp capability_description(state, _environment, _arguments),
    do: protocol_error(state, :invalid_capability_description_request)

  defp maybe_put_annotation(tools, state, event_sink, :workflow) do
    Map.put(tools, "workflow-annotate", fn arguments ->
      annotate(state, event_sink, arguments)
    end)
  end

  defp maybe_put_annotation(tools, _state, _event_sink, :mission), do: tools

  defp annotate(state, event_sink, %{"type" => type, "data" => data})
       when is_binary(type) do
    limit = RunState.limits(state).event_payload_bytes
    payload = %{annotation_type: type, data: data, provenance: :workflow}
    bytes = RetainedSize.bytes_with_cap(payload, limit)

    if String.valid?(type) and byte_size(type) <= 128 and JSONValue.value?(data) and
         is_integer(bytes) and bytes <= limit do
      case Events.emit(state, event_sink, "workflow-annotation", payload) do
        :ok -> %{status: :ok}
        {:error, :event_sink_error} -> %{status: :error, kind: :event_sink_error}
      end
    else
      protocol_error(state, :invalid_workflow_annotation)
    end
  end

  defp annotate(state, _event_sink, _arguments),
    do: protocol_error(state, :invalid_workflow_annotation)

  defp protocol_error(state, reason) do
    case RunState.protocol_error(state) do
      :ok ->
        %{status: :error, kind: :protocol_error, reason: reason}

      {:error, :protocol_error_limit} ->
        %{status: :error, kind: :limit_exceeded, reason: :protocol_errors}
    end
  end

  defp result_status(%{status: status}), do: status
  defp result_status(_result), do: :ok
end
