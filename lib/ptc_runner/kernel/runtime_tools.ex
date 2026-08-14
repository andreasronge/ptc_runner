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
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Program
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.SourceCheck
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.Lisp.TrustedError
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

  @doc """
  Builds the reserved runtime-tool map for one environment.

  Mission grants carry the constructing evaluation's lease via
  `opts[:lease]`: a stale call fails closed before instrumentation (no
  events, no state read), and malformed-call accounting authenticates the
  lease atomically so a dead evaluation cannot spend the next one's
  protocol-error budget through a runtime route.
  """
  def tools(state, environment, event_sink, kind, opts \\ [])
      when kind in [:workflow, :mission] do
    lease = Keyword.get(opts, :lease)
    mission_name = Keyword.get(opts, :mission_name)
    # cap-list/cap-describe are the discovery routes that legitimately need
    # every capability; runtime-usage/runtime-remaining ignore this argument.
    # Narrowing here (rather than per-route) keeps the whole environment from
    # being captured even once per callback. See PtcRunner.Kernel.ToolGrant.
    view = Environment.capability_view(environment)

    @mission_routes
    |> Map.new(fn {name, route} -> {name, route_callback(route, state, view, kind, lease)} end)
    |> maybe_put_annotation(state, event_sink, kind)
    |> Map.new(fn {name, callback} ->
      attributes =
        if kind == :mission and is_binary(mission_name),
          do: %{mission_name: mission_name},
          else: %{}

      instrumented = instrument(state, event_sink, kind, name, callback, attributes)
      {name, authenticate_mission_route(instrumented, state, kind, lease)}
    end)
  end

  defp authenticate_mission_route(callback, _state, :workflow, _lease), do: callback

  defp authenticate_mission_route(callback, state, :mission, lease) do
    fn arguments ->
      if RunState.mission_lease_current?(state, lease) do
        callback.(arguments)
      else
        %{
          status: :error,
          kind: :capability_denied,
          reason: :stale_evaluation,
          retryable?: false
        }
      end
    end
  end

  @doc "Builds the workflow-only frozen mission-inventory callback."
  def mission_inventory(state, rendered_by_mission) when is_map(rendered_by_mission),
    do: frozen_by_mission(state, rendered_by_mission, :invalid_mission_inventory_request)

  @doc "Builds the workflow-only frozen compact mission-model-context callback."
  def mission_model_context(state, rendered_by_mission) when is_map(rendered_by_mission),
    do: frozen_by_mission(state, rendered_by_mission, :invalid_mission_model_context_request)

  defp frozen_by_mission(state, rendered_by_mission, invalid_reason) do
    fn arguments ->
      with {:ok, mission_name} <- requested_mission(arguments),
           {:ok, rendered} <- Map.fetch(rendered_by_mission, mission_name) do
        %{status: :ok, value: rendered}
      else
        :error -> protocol_error(state, :unknown_mission)
        {:error, :invalid_request} -> protocol_error(state, invalid_reason)
      end
    end
  end

  @doc """
  Builds the workflow-only subordinate-evaluation callback.

  `opts` accepts `admission: :block | :fail_fast` (default `:fail_fast`).
  The Runner's workflow route blocks, so concurrent agent loops queue behind
  the single evaluation lease instead of failing. The REPL keeps fail-fast:
  a REPL expression evaluates under the session's own lease, so a blocking
  nested `kernel-eval` would park behind itself until the sandbox timeout.
  """
  def kernel_eval(state, missions, limits, event_sink, inspection_sink \\ nil, opts \\ [])
      when is_map(missions) and not is_struct(missions) do
    admission = Keyword.get(opts, :admission, :fail_fast)

    fn arguments ->
      case take_mission(arguments, missions) do
        {:ok, mission_name, mission, arguments} ->
          dispatch_kernel_eval(
            state,
            {mission_name, mission},
            arguments,
            limits,
            event_sink,
            inspection_sink,
            admission
          )

        :error ->
          protocol_error(state, :unknown_mission)

        {:error, :invalid_request} ->
          invalid_kernel_eval_request(state)
      end
    end
  end

  @doc false
  @spec runtime_limit_failure(RunState.t(), map()) :: (map() -> term())
  def runtime_limit_failure(state, limits) do
    fn arguments ->
      with %{"proof" => proof} <- arguments,
           true <- map_size(arguments) == 1,
           :ok <- RunState.consume_evaluation_limit_proof(state, proof) do
        %TrustedError{
          reason: :runtime_limit_exceeded,
          message: "subordinate_evaluations limit exceeded",
          details: %{
            limit: :subordinate_evaluations,
            limit_value: limits.subordinate_evaluations
          }
        }
      else
        _failure ->
          %{
            status: :error,
            kind: :protocol_error,
            reason: :invalid_runtime_limit_failure
          }
      end
    end
  end

  @doc false
  @spec maybe_put_runtime_limit_failure(map(), RunState.t(), term(), map(), term()) :: map()
  def maybe_put_runtime_limit_failure(tools, state, event_sink, limits, bundle)
      when is_map(tools) do
    if Library.shipped_component?(bundle, "agent.core") do
      Map.put(
        tools,
        "kernel-runtime-limit-failure",
        instrument(
          state,
          event_sink,
          :workflow,
          "kernel-runtime-limit-failure",
          runtime_limit_failure(state, limits)
        )
      )
    else
      tools
    end
  end

  defp dispatch_kernel_eval(
         state,
         target,
         arguments,
         limits,
         event_sink,
         inspection_sink,
         admission
       ) do
    case arguments do
      %{"kind" => kind, "source" => source} = arguments
      when is_binary(source) and map_size(arguments) == 2 ->
        if keyword_name(kind) == "source" do
          evaluate_source(state, target, source, limits, event_sink, inspection_sink, admission)
        else
          invalid_kernel_eval_request(state)
        end

      %{"kind" => kind, "source" => source, "params" => params} = arguments
      when is_binary(source) and map_size(arguments) == 3 ->
        if keyword_name(kind) == "source" do
          evaluate_source_with(
            state,
            target,
            source,
            params,
            limits,
            event_sink,
            inspection_sink,
            admission
          )
        else
          invalid_kernel_eval_request(state)
        end

      %{"kind" => kind, "program" => %Program{source: source}} = arguments
      when map_size(arguments) == 2 ->
        if keyword_name(kind) == "embedded" do
          evaluate_source(state, target, source, limits, event_sink, inspection_sink, admission)
        else
          invalid_kernel_eval_request(state)
        end

      %{"kind" => kind, "program" => %Program{source: source}, "params" => params} = arguments
      when map_size(arguments) == 3 ->
        if keyword_name(kind) == "embedded" do
          evaluate_source_with(
            state,
            target,
            source,
            params,
            limits,
            event_sink,
            inspection_sink,
            admission
          )
        else
          invalid_kernel_eval_request(state)
        end

      _rest ->
        invalid_kernel_eval_request(state)
    end
  end

  @doc "Builds the workflow-only mission-aware source-check callback."
  def kernel_check_source(state, missions, limits, event_sink) when is_map(missions) do
    fn arguments ->
      with {:ok, mission_name, mission, %{"source" => source} = rest} <-
             take_mission(arguments, missions),
           true <- is_binary(source) and map_size(rest) == 1 do
        %{
          status: :ok,
          value: SourceCheck.check(state, mission_name, mission, source, limits, event_sink, [])
        }
      else
        :error -> protocol_error(state, :unknown_mission)
        _ -> invalid_kernel_check_source_request(state)
      end
    end
  end

  defp requested_mission(arguments) when is_map(arguments) do
    case arguments do
      %{"mission" => mission_name} = map when is_binary(mission_name) and map_size(map) == 1 ->
        {:ok, mission_name}

      _other ->
        {:error, :invalid_request}
    end
  end

  defp requested_mission(_arguments), do: {:error, :invalid_request}

  defp take_mission(arguments, missions) when is_map(arguments) do
    case Map.pop(arguments, "mission") do
      {mission_name, rest} when is_binary(mission_name) ->
        case Map.fetch(missions, mission_name) do
          {:ok, mission} -> {:ok, mission_name, mission, rest}
          :error -> :error
        end

      _other ->
        {:error, :invalid_request}
    end
  end

  defp take_mission(_arguments, _missions), do: {:error, :invalid_request}

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

      {"kernel-result-contract" = name, callback} ->
        {name,
         %TrustedTool{
           function: callback,
           argument_projection: :raw
         }}

      {"kernel-runtime-limit-failure" = name, callback} ->
        {name,
         %TrustedTool{
           function: callback,
           prelude_namespaces: ["agent.core"],
           visibility: :private
         }}

      {name, callback} ->
        {name, %TrustedTool{function: callback}}
    end)
  end

  defp evaluate_source(
         state,
         {mission_name, mission},
         source,
         limits,
         event_sink,
         inspection_sink,
         admission
       ) do
    %{
      status: :ok,
      value:
        state
        |> Evaluation.evaluate_source(
          mission_name,
          mission,
          source,
          limits.evaluation_timeout_ms,
          event_sink,
          inspection_sink,
          admission: admission
        )
    }
  end

  defp evaluate_source_with(
         state,
         {mission_name, mission},
         source,
         params,
         limits,
         event_sink,
         inspection_sink,
         admission
       ) do
    case normalize_params(params, limits.capability_argument_bytes) do
      {:ok, params} ->
        %{
          status: :ok,
          value:
            state
            |> Evaluation.evaluate_source(
              mission_name,
              mission,
              source,
              limits.evaluation_timeout_ms,
              event_sink,
              inspection_sink,
              params: params,
              admission: admission
            )
        }

      {:error, _reason} ->
        invalid_kernel_eval_request(state)
    end
  end

  defp normalize_params(params, max_bytes) do
    with false <- contains_program?(params),
         {:ok, projected} <- Lisp.project_boundary_value(params, :kernel_json),
         true <- JSONValue.value?(projected),
         bytes when is_integer(bytes) and bytes <= max_bytes <-
           RetainedSize.bytes_with_cap(projected, max_bytes) do
      {:ok, RetainedSize.detach_binaries(projected)}
    else
      _other -> {:error, :invalid_params}
    end
  end

  defp contains_program?(%Program{}), do: true

  defp contains_program?(value) when is_map(value) and not is_struct(value) do
    Enum.any?(value, fn {key, item} -> contains_program?(key) or contains_program?(item) end)
  end

  defp contains_program?(value) when is_list(value), do: Enum.any?(value, &contains_program?/1)

  defp contains_program?(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.any?(&contains_program?/1)
  end

  defp contains_program?(_value), do: false

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
      %{"value" => _value} = arguments when map_size(arguments) == 1 ->
        %{status: :ok, value: %{enforced?: false, valid?: true}}

      _arguments ->
        %{status: :error, kind: :protocol_error, reason: :invalid_result_contract_request}
    end
  end

  def result_contract(%ValueContract{} = contract) do
    fn
      %{"value" => value} = arguments when map_size(arguments) == 1 ->
        validate_result_contract(contract, value)

      _arguments ->
        %{status: :error, kind: :protocol_error, reason: :invalid_result_contract_request}
    end
  end

  defp validate_result_contract(contract, value) do
    with {:ok, projected} <- Lisp.project_boundary_value(value, :kernel_json),
         {:ok, json_value} <- ValueContract.json_value(projected) do
      if ValueContract.valid?(contract, json_value) do
        %{status: :ok, value: %{enforced?: true, valid?: true}}
      else
        invalid_result_contract(ValueContract.classify(contract, json_value))
      end
    else
      {:error, _reason} ->
        invalid_json_result_contract(contract, value)
    end
  end

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
  def instrument(state, event_sink, environment, name, callback, attributes \\ %{})
      when environment in [:workflow, :mission] and is_binary(name) and is_function(callback, 1) and
             is_map(attributes) do
    fn arguments ->
      capability_id = Events.id("capability")
      started_ms = System.monotonic_time(:millisecond)

      started =
        Map.merge(attributes, %{
          capability_id: capability_id,
          environment: environment,
          name: name
        })

      case Events.emit(state, event_sink, "capability-started", started) do
        :ok ->
          result = callback.(arguments)

          _ =
            Events.emit(
              state,
              event_sink,
              "capability-stopped",
              Map.merge(attributes, %{
                capability_id: capability_id,
                environment: environment,
                name: name,
                status: result_status(result),
                duration_ms: Events.duration_ms(started_ms)
              })
            )

          result

        {:error, :event_sink_error} ->
          %{status: :error, kind: :event_sink_error, reason: :event_sink_error}
      end
    end
  end

  defp usage(state, arguments, _scope) when is_map(arguments) and map_size(arguments) == 0,
    do: RunState.usage(state)

  defp usage(state, _arguments, scope),
    do: scoped_protocol_error(state, :invalid_runtime_usage_request, scope)

  defp remaining(state, arguments, _scope) when is_map(arguments) and map_size(arguments) == 0,
    do: RunState.remaining_ms(state)

  defp remaining(state, _arguments, scope),
    do: scoped_protocol_error(state, :invalid_runtime_remaining_request, scope)

  defp capability_list(_state, environment, arguments, _scope)
       when is_map(arguments) and map_size(arguments) == 0,
       do: Environment.metadata(environment)

  defp capability_list(state, _environment, _arguments, scope),
    do: scoped_protocol_error(state, :invalid_capability_list_request, scope)

  defp capability_description(_state, environment, %{"name" => name}, _scope)
       when is_binary(name) do
    Enum.find(Environment.metadata(environment), &(&1.name == name))
  end

  defp capability_description(state, _environment, _arguments, scope),
    do: scoped_protocol_error(state, :invalid_capability_description_request, scope)

  defp route_callback(:usage, state, _environment, kind, lease),
    do: fn arguments -> usage(state, arguments, {kind, lease}) end

  defp route_callback(:remaining, state, _environment, kind, lease),
    do: fn arguments -> remaining(state, arguments, {kind, lease}) end

  defp route_callback(:capability_list, state, environment, kind, lease),
    do: fn arguments -> capability_list(state, environment, arguments, {kind, lease}) end

  defp route_callback(:capability_description, state, environment, kind, lease),
    do: fn arguments -> capability_description(state, environment, arguments, {kind, lease}) end

  # Malformed-call accounting for a mission route authenticates the lease in
  # the same owner operation that records the error.
  defp scoped_protocol_error(state, reason, {kind, lease}) do
    case RunState.protocol_error(state, kind, lease) do
      :ok ->
        %{status: :error, kind: :protocol_error, reason: reason}

      {:error, :stale_evaluation} ->
        %{status: :error, kind: :capability_denied, reason: :stale_evaluation, retryable?: false}

      {:error, :protocol_error_limit} ->
        %{status: :error, kind: :limit_exceeded, reason: :protocol_errors}
    end
  end

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
