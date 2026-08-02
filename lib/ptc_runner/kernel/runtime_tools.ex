defmodule PtcRunner.Kernel.RuntimeTools do
  @moduledoc """
  Internal construction of reserved runtime capabilities.

  Both environments receive read-only usage and local capability discovery.
  Only the workflow receives the annotation route. Annotation data uses a
  finite type/key/value vocabulary, not caller-defined scalar metadata or
  arbitrary JSON payloads. Every route is instrumented with the same canonical
  capability start/stop events.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.Environment
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.Program
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.SourceCheck
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.Lisp.TrustedTool

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
  def tools(state, environment, event_sink, kind, evaluation_id \\ nil)
      when kind in [:workflow, :mission] do
    @mission_routes
    |> Map.new(fn {name, route} -> {name, route_callback(route, state, environment)} end)
    |> maybe_put_annotation(state, environment, event_sink, kind, evaluation_id)
    |> Map.new(fn {name, callback} ->
      {name, instrument(state, event_sink, kind, name, callback, evaluation_id)}
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
      %{"kind" => kind, "source" => source} = arguments
      when is_binary(source) and map_size(arguments) == 2 ->
        if keyword_name(kind) == "source" do
          evaluate_source(state, mission, source, limits, event_sink, inspection_sink)
        else
          invalid_kernel_eval_request(state)
        end

      %{"kind" => kind, "source" => source, "params" => params} = arguments
      when is_binary(source) and map_size(arguments) == 3 ->
        if keyword_name(kind) == "source" do
          evaluate_source_with(
            state,
            mission,
            source,
            params,
            limits,
            event_sink,
            inspection_sink
          )
        else
          invalid_kernel_eval_request(state)
        end

      %{"kind" => kind, "program" => %Program{source: source}} = arguments
      when map_size(arguments) == 2 ->
        if keyword_name(kind) == "embedded" do
          evaluate_source(state, mission, source, limits, event_sink, inspection_sink)
        else
          invalid_kernel_eval_request(state)
        end

      %{"kind" => kind, "program" => %Program{source: source}, "params" => params} = arguments
      when map_size(arguments) == 3 ->
        if keyword_name(kind) == "embedded" do
          evaluate_source_with(
            state,
            mission,
            source,
            params,
            limits,
            event_sink,
            inspection_sink
          )
        else
          invalid_kernel_eval_request(state)
        end

      _arguments ->
        invalid_kernel_eval_request(state)
    end
  end

  @doc "Builds the workflow-only mission-aware source-check callback."
  def kernel_check_source(state, mission, limits, event_sink) do
    fn
      %{"source" => source} = arguments
      when is_binary(source) and map_size(arguments) == 1 ->
        %{
          status: :ok,
          value: SourceCheck.check(state, mission, source, limits, event_sink)
        }

      _arguments ->
        invalid_kernel_check_source_request(state)
    end
  end

  @doc false
  @spec kernel_eval_ledger_arguments(map()) :: (map() -> map())
  def kernel_eval_ledger_arguments(limits) do
    fn arguments -> project_kernel_eval_arguments(arguments, limits) end
  end

  @doc false
  @spec kernel_check_source_ledger_arguments(map()) :: (map() -> map())
  def kernel_check_source_ledger_arguments(limits) do
    fn arguments -> project_kernel_check_source_arguments(arguments, limits) end
  end

  @doc false
  @spec trusted_tools(map(), map()) :: map()
  def trusted_tools(tools, limits) when is_map(tools) do
    Map.new(tools, fn
      {"kernel-eval" = name, callback} ->
        {name,
         %TrustedTool{
           function: callback,
           ledger_arguments: kernel_eval_ledger_arguments(limits)
         }}

      {"kernel-check-source" = name, callback} ->
        {name,
         %TrustedTool{
           function: callback,
           ledger_arguments: kernel_check_source_ledger_arguments(limits)
         }}

      {name, callback} ->
        {name, %TrustedTool{function: callback}}
    end)
  end

  defp evaluate_source(state, mission, source, limits, event_sink, inspection_sink) do
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
  end

  defp evaluate_source_with(
         state,
         mission,
         source,
         params,
         limits,
         event_sink,
         inspection_sink
       ) do
    case normalize_params(params, limits.capability_argument_bytes) do
      {:ok, params} ->
        %{
          status: :ok,
          value:
            Evaluation.evaluate_source(
              state,
              mission,
              source,
              limits.evaluation_timeout_ms,
              event_sink,
              inspection_sink,
              params
            )
        }

      {:error, _reason} ->
        invalid_kernel_eval_request(state)
    end
  end

  defp normalize_params(params, max_bytes) do
    with {:ok, projected} <- Lisp.project_boundary_value(params, :kernel_json),
         true <- JSONValue.value?(projected),
         bytes when is_integer(bytes) and bytes <= max_bytes <-
           RetainedSize.bytes_with_cap(projected, max_bytes) do
      {:ok, RetainedSize.detach_binaries(projected)}
    else
      _other -> {:error, :invalid_params}
    end
  end

  defp project_kernel_eval_arguments(arguments, limits) when is_map(arguments) do
    %{}
    |> maybe_put_kind(arguments)
    |> maybe_put_source_identity(arguments, limits.subordinate_source_bytes)
    |> maybe_put_program_identity(arguments)
    |> maybe_put_params_identity(arguments, limits.capability_argument_bytes)
  end

  defp project_kernel_eval_arguments(_arguments, _limits), do: %{"redacted" => true}

  defp project_kernel_check_source_arguments(arguments, limits) when is_map(arguments) do
    maybe_put_source_identity(%{}, arguments, limits.subordinate_source_bytes)
  end

  defp project_kernel_check_source_arguments(_arguments, _limits),
    do: %{"redacted" => true}

  defp maybe_put_kind(projected, arguments) do
    case keyword_name(Map.get(arguments, "kind")) do
      kind when kind in ["embedded", "source"] -> Map.put(projected, "kind", kind)
      _other -> projected
    end
  end

  defp maybe_put_source_identity(projected, arguments, max_bytes) do
    case Map.get(arguments, "source") do
      source when is_binary(source) and byte_size(source) <= max_bytes ->
        Map.put(projected, "source", source_identity(source))

      source when is_binary(source) ->
        Map.put(projected, "source", %{"bytes" => byte_size(source)})

      _other ->
        projected
    end
  end

  defp maybe_put_program_identity(projected, arguments) do
    case Map.get(arguments, "program") do
      %Program{byte_size: bytes, digest: digest} ->
        Map.put(projected, "program", %{
          "bytes" => bytes,
          "sha256" => "sha256:" <> digest
        })

      _other ->
        projected
    end
  end

  defp maybe_put_params_identity(projected, arguments, max_bytes) do
    case Map.fetch(arguments, "params") do
      {:ok, params} ->
        identity =
          case normalize_params(params, max_bytes) do
            {:ok, normalized} -> json_identity(normalized)
            {:error, _reason} -> %{"invalid" => true}
          end

        Map.put(projected, "params", identity)

      :error ->
        projected
    end
  end

  defp json_identity(value) do
    case DeterministicJSON.encode(value) do
      {:ok, encoded} -> source_identity(encoded)
      {:error, _reason} -> %{"invalid" => true}
    end
  end

  defp source_identity(source) do
    %{
      "bytes" => byte_size(source),
      "sha256" => "sha256:" <> Base.encode16(:crypto.hash(:sha256, source), case: :lower)
    }
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

  @doc "Builds the workflow-only application-result contract description callback."
  def result_contract_description(nil), do: result_contract_description_callback(nil)

  def result_contract_description(%ValueContract{} = contract) do
    contract
    |> ValueContract.describe()
    |> result_contract_description_callback()
  end

  defp result_contract_description_callback(description) do
    fn
      arguments when is_map(arguments) and map_size(arguments) == 0 ->
        %{status: :ok, value: description}

      _arguments ->
        %{
          status: :error,
          kind: :protocol_error,
          reason: :invalid_result_contract_description_request
        }
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
  def instrument(state, event_sink, environment, name, callback, evaluation_id \\ nil)
      when environment in [:workflow, :mission] and is_binary(name) and is_function(callback, 1) do
    fn arguments ->
      capability_id = Events.id("capability")
      started_ms = System.monotonic_time(:millisecond)

      started =
        put_evaluation_id(
          %{capability_id: capability_id, environment: environment, name: name},
          evaluation_id
        )

      case Events.emit(state, event_sink, "capability-started", started) do
        :ok ->
          result = callback.(arguments)

          _ =
            Events.emit(
              state,
              event_sink,
              "capability-stopped",
              put_evaluation_id(
                %{
                  capability_id: capability_id,
                  environment: environment,
                  name: name,
                  status: result_status(result),
                  duration_ms: Events.duration_ms(started_ms)
                },
                evaluation_id
              )
            )

          result

        {:error, :event_sink_error} ->
          %{status: :error, kind: :event_sink_error, reason: :event_sink_error}
      end
    end
  end

  defp put_evaluation_id(data, evaluation_id) when is_binary(evaluation_id),
    do: Map.put(data, :evaluation_id, evaluation_id)

  defp put_evaluation_id(data, _evaluation_id), do: data

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

  defp maybe_put_annotation(tools, state, environment, event_sink, :workflow, evaluation_id) do
    # Read off the view, not the environment: the declaration is fixed by the
    # frozen bundle, and a callback must not capture the bundle behind it.
    declared = Map.get(environment, :annotations, %{})

    Map.put(tools, "workflow-annotate", fn arguments ->
      annotate(state, declared, event_sink, evaluation_id, arguments)
    end)
  end

  defp maybe_put_annotation(tools, _state, _environment, _event_sink, :mission, _evaluation_id),
    do: tools

  # The evaluation_id is added to `payload` before it is measured, exactly
  # like the same field on capability events (see `put_evaluation_id/2`
  # above): adding it after `RetainedSize.bytes_with_cap/2` would emit a
  # payload larger than the one the bound just approved.
  defp annotate(state, declared, event_sink, evaluation_id, %{"type" => type, "data" => data})
       when is_binary(type) do
    limit = RunState.limits(state).event_payload_bytes

    payload =
      put_evaluation_id(
        %{annotation_type: type, data: data, provenance: :workflow},
        evaluation_id
      )

    bytes = RetainedSize.bytes_with_cap(payload, limit)

    if SafeMetadata.annotation?(type, data, declared) and is_integer(bytes) and bytes <= limit do
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

  defp annotate(state, _declared, _event_sink, _evaluation_id, _arguments),
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

  defp invalid_kernel_check_source_request(state) do
    case RunState.protocol_error(state) do
      :ok ->
        %{
          status: :error,
          kind: :protocol_error,
          reason: :invalid_kernel_check_source_request,
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
