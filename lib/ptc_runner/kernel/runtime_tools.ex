defmodule PtcRunner.Kernel.RuntimeTools do
  @moduledoc """
  Internal construction of reserved runtime capabilities.

  Both environments receive read-only usage and local capability discovery.
  Only the workflow receives the annotation route. Annotation data uses a
  finite type/key/value vocabulary, not caller-defined scalar metadata or
  arbitrary JSON payloads. Every route is instrumented with the same canonical
  capability start/stop events.
  """

  alias PtcRunner.Kernel.Environment
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.Program
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.RetainedSize

  @mission_contract_version 1
  @mission_routes [
    {"cap-describe", :capability_description},
    {"cap-list", :capability_list},
    {"runtime-remaining", :remaining},
    {"runtime-usage", :usage}
  ]

  @doc false
  @spec mission_contract_descriptor() :: map()
  def mission_contract_descriptor do
    %{
      "version" => @mission_contract_version,
      "routes" => Enum.map(@mission_routes, &elem(&1, 0))
    }
  end

  @doc "Builds the reserved runtime-tool map for one environment."
  def tools(state, environment, event_sink, kind) when kind in [:workflow, :mission] do
    @mission_routes
    |> Map.new(fn {name, route} -> {name, route_callback(route, state, environment)} end)
    |> maybe_put_annotation(state, event_sink, kind)
    |> Map.new(fn {name, callback} ->
      {name, instrument(state, event_sink, kind, name, callback)}
    end)
  end

  @doc "Builds the workflow-only frozen mission-inventory callback."
  def mission_inventory(state, rendered) when is_binary(rendered) do
    fn
      arguments when is_map(arguments) and map_size(arguments) == 0 ->
        %{status: :ok, value: rendered}

      _arguments ->
        protocol_error(state, :invalid_mission_inventory_request)
    end
  end

  @doc "Builds the workflow-only frozen compact mission-model-context callback."
  def mission_model_context(state, rendered) when is_binary(rendered) do
    fn
      arguments when is_map(arguments) and map_size(arguments) == 0 ->
        %{status: :ok, value: rendered}

      _arguments ->
        protocol_error(state, :invalid_mission_model_context_request)
    end
  end

  @doc "Builds the workflow-only subordinate-evaluation callback."
  def kernel_eval(state, mission, limits, event_sink, inspection_sink \\ nil) do
    fn
      %{"kind" => kind, "source" => source} when is_binary(source) ->
        if keyword_name(kind) == "source" do
          %{
            status: :ok,
            value:
              Evaluation.evaluate_source(
                state,
                mission,
                source,
                limits.evaluation_timeout_ms,
                event_sink,
                inspection_sink
              )
          }
        else
          invalid_kernel_eval_request(state)
        end

      %{"kind" => kind, "program" => %Program{source: source}} ->
        if keyword_name(kind) == "embedded" do
          %{
            status: :ok,
            value:
              Evaluation.evaluate_source(
                state,
                mission,
                source,
                limits.evaluation_timeout_ms,
                event_sink,
                inspection_sink
              )
          }
        else
          invalid_kernel_eval_request(state)
        end

      _arguments ->
        invalid_kernel_eval_request(state)
    end
  end

  @doc "Builds the workflow-only application-result contract callback."
  def result_contract(nil) do
    fn
      %{"value" => _value, "json_value" => json_value?} when is_boolean(json_value?) ->
        %{status: :ok, value: %{enforced?: false, valid?: true}}

      _arguments ->
        %{status: :error, kind: :protocol_error, reason: :invalid_result_contract_request}
    end
  end

  def result_contract(%ValueContract{} = contract) do
    fn
      %{"value" => value, "json_value" => json_value?} when is_boolean(json_value?) ->
        validate_result_contract(contract, value, json_value?)

      _arguments ->
        %{status: :error, kind: :protocol_error, reason: :invalid_result_contract_request}
    end
  end

  defp validate_result_contract(contract, value, true) do
    case ValueContract.json_value(value) do
      {:ok, json_value} ->
        if ValueContract.valid?(contract, json_value) do
          %{status: :ok, value: %{enforced?: true, valid?: true}}
        else
          invalid_result_contract(ValueContract.classify(contract, json_value))
        end

      {:error, _reason} ->
        invalid_json_result_contract(contract, value)
    end
  end

  defp validate_result_contract(contract, value, false),
    do: invalid_json_result_contract(contract, value)

  defp invalid_json_result_contract(contract, value) do
    details =
      contract
      |> ValueContract.classify(value)
      |> Map.put(:json_value, false)
      |> Map.put(:violations, [])

    invalid_result_contract(details)
  end

  defp invalid_result_contract(details) do
    %{status: :ok, value: %{enforced?: true, valid?: false, details: details}}
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

  defp route_callback(:usage, state, _environment),
    do: fn arguments -> usage(state, arguments) end

  defp route_callback(:remaining, state, _environment),
    do: fn arguments -> remaining(state, arguments) end

  defp route_callback(:capability_list, state, environment),
    do: fn arguments -> capability_list(state, environment, arguments) end

  defp route_callback(:capability_description, state, environment),
    do: fn arguments -> capability_description(state, environment, arguments) end

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

    if SafeMetadata.annotation?(type, data) and is_integer(bytes) and bytes <= limit do
      case Events.emit(state, event_sink, "workflow-annotation", payload) do
        :ok -> %{status: :ok}
        {:error, :event_sink_error} -> %{status: :error, kind: :event_sink_error}
      end
    else
      %{
        status: :error,
        kind: :invalid_annotation,
        reason: :invalid_workflow_annotation
      }
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

  defp invalid_kernel_eval_request(state) do
    case RunState.protocol_error(state) do
      :ok ->
        %{
          status: :error,
          kind: :protocol_error,
          reason: :invalid_kernel_eval_request,
          retryable?: false
        }

      {:error, :protocol_error_limit} ->
        %{status: :error, kind: :limit_exceeded, reason: :protocol_errors, retryable?: false}
    end
  end

  defp keyword_name(%LispKeyword{name: name}), do: name
  defp keyword_name(name) when is_atom(name), do: Atom.to_string(name)
  defp keyword_name(name) when is_binary(name), do: name
  defp keyword_name(_value), do: nil

  defp result_status(%{status: status}), do: status
  defp result_status(_result), do: :ok
end
