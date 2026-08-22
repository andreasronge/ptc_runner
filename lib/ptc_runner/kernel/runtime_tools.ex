defmodule PtcRunner.Kernel.RuntimeTools do
  @moduledoc """
  Internal construction of reserved runtime capabilities.

  Both environments receive read-only usage and local capability discovery.
  Only the workflow receives the annotation route. Annotation data uses a
  finite type/key vocabulary with closed enumerations, plus a bounded mission
  identifier on phased agent-action records — not arbitrary JSON payloads. Every route is instrumented with the same canonical
  capability start/stop events.
  """

  alias PtcRunner.Kernel.AgentConfigDiagnostic
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.Environment
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.EvaluationObservation
  alias PtcRunner.Kernel.Events
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.LLMReplayDiagnostic
  alias PtcRunner.Kernel.Program
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.SourceCheck
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Kernel.ValueContractDiagnostic
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.Lisp.TrustedError
  alias PtcRunner.Lisp.TrustedTool
  alias PtcRunner.LLM.OutputLimit

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
    |> Map.new(fn {name, route} ->
      {name, route_callback(route, state, view, event_sink, kind, lease)}
    end)
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
  def mission_inventory(state, rendered_by_mission, event_sink)
      when is_map(rendered_by_mission),
      do:
        frozen_by_mission(
          state,
          rendered_by_mission,
          event_sink,
          :invalid_mission_inventory_request
        )

  @doc "Builds the workflow-only frozen compact mission-model-context callback."
  def mission_model_context(state, rendered_by_mission, event_sink)
      when is_map(rendered_by_mission),
      do:
        frozen_by_mission(
          state,
          rendered_by_mission,
          event_sink,
          :invalid_mission_model_context_request
        )

  defp frozen_by_mission(state, rendered_by_mission, event_sink, invalid_reason) do
    fn arguments ->
      with {:ok, mission_name} <- requested_mission(arguments),
           {:ok, rendered} <- Map.fetch(rendered_by_mission, mission_name) do
        %{status: :ok, value: rendered}
      else
        :error -> protocol_error(state, event_sink, :unknown_mission)
        {:error, :invalid_request} -> protocol_error(state, event_sink, invalid_reason)
      end
    end
  end

  @doc """
  Builds the workflow-only subordinate-evaluation callback.

  `opts` accepts `admission: :block | :fail_fast` (default `:fail_fast`) and an
  optional `parent_evaluation_id` for the enclosing workflow evaluation.
  The Runner's workflow route blocks, so concurrent agent loops queue behind
  the single evaluation lease instead of failing. The REPL keeps fail-fast:
  a REPL expression evaluates under the session's own lease, so a blocking
  nested `kernel-eval` would park behind itself until the sandbox timeout.
  """
  def kernel_eval(state, missions, limits, event_sink, inspection_sink \\ nil, opts \\ [])
      when is_map(missions) and not is_struct(missions) do
    evaluation_opts = [
      admission: Keyword.get(opts, :admission, :fail_fast),
      parent_evaluation_id: Keyword.get(opts, :parent_evaluation_id)
    ]

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
            evaluation_opts
          )

        :error ->
          protocol_error(state, event_sink, :unknown_mission)

        {:error, :invalid_request} ->
          invalid_kernel_eval_request(state, event_sink)
      end
    end
  end

  @doc false
  @spec runtime_limit_failure(RunState.t(), map()) :: (map() -> term())
  def runtime_limit_failure(state, limits) do
    fn arguments ->
      case arguments do
        %{"proof" => proof} when map_size(arguments) == 1 ->
          case RunState.consume_evaluation_limit_proof(state, proof) do
            :ok ->
              %TrustedError{
                reason: :runtime_limit_exceeded,
                message: "subordinate_evaluations limit exceeded",
                details: %{
                  limit: :subordinate_evaluations,
                  limit_value: limits.subordinate_evaluations
                }
              }

            _failure ->
              invalid_runtime_limit_failure()
          end

        %{"agent_turns" => limit, "reason" => reason}
        when map_size(arguments) == 2 and limit in 1..128 ->
          agent_turn_limit_failure(limit, reason)

        # The transcript ceiling is a bound the caller set in the input document
        # it just wrote, so it reports itself the way the turn limit does rather
        # than reaching the generic workflow failure.
        %{"max_transcript_chars" => limit}
        when map_size(arguments) == 1 and limit in 1..1_000_000 ->
          %TrustedError{
            reason: :runtime_limit_exceeded,
            message: "transcript limit exceeded",
            details: %{limit: :max_transcript_chars, limit_value: limit}
          }

        %{"max_tokens" => value, "bindings" => bindings, "alias" => alias_name}
        when map_size(arguments) == 3 ->
          model_output_truncation_failure(value, bindings, alias_name)

        %{"alias" => alias_name} when map_size(arguments) == 1 ->
          model_output_truncation_failure(alias_name)

        _invalid ->
          invalid_runtime_limit_failure()
      end
    end
  end

  # The loop reports why it stopped, not only that it stopped. An unrecognised
  # reason is refused rather than collapsed into the ordinary exhaustion case:
  # a wrong explanation costs the reader more than a missing one.
  defp agent_turn_limit_failure(limit, reason) do
    case RuntimeLimitDiagnostic.agent_turns_reason(reason) do
      {:ok, reason} ->
        %TrustedError{
          reason: :runtime_limit_exceeded,
          message: "agent turn limit exceeded",
          details: %{limit: :agent_turns, limit_value: limit, limit_reason: reason}
        }

      :error ->
        invalid_runtime_limit_failure()
    end
  end

  defp model_output_truncation_failure(value, bindings, alias_name) do
    with {:ok, limit} <-
           OutputLimit.normalize(%{name: :max_tokens, value: value, bindings: bindings}),
         true <- OutputLimit.valid_alias?(alias_name) do
      %TrustedError{
        reason: :model_output_truncated,
        message: "model output was truncated before a usable agent action",
        details: %{
          limit: :max_tokens,
          limit_value: limit.value,
          limit_bindings: limit.bindings,
          alias: alias_name
        }
      }
    else
      _invalid -> invalid_runtime_limit_failure()
    end
  end

  defp model_output_truncation_failure(alias_name) do
    if OutputLimit.valid_alias?(alias_name) do
      %TrustedError{
        reason: :model_output_truncated,
        message: "model output was truncated before a usable agent action",
        details: %{alias: alias_name}
      }
    else
      invalid_runtime_limit_failure()
    end
  end

  defp invalid_runtime_limit_failure do
    %{
      status: :error,
      kind: :protocol_error,
      reason: :invalid_runtime_limit_failure
    }
  end

  @doc false
  @spec llm_provider_failure(RunState.t()) :: (map() -> term())
  def llm_provider_failure(state) do
    fn arguments ->
      case SafeMetadata.llm_provider_failure(arguments) do
        %{
          llm_provider_failure: failure,
          llm_provider_retryable?: retryable?
        } = details ->
          case RunState.consume_llm_provider_failure(state, failure, retryable?) do
            :ok ->
              %TrustedError{
                reason: :llm_provider_failed,
                message: "LLM provider request failed",
                details:
                  details
                  |> Map.put(:failure_kind, "llm-provider-error")
                  |> maybe_put_authenticated_replay(arguments, state)
              }

            :error ->
              invalid_llm_provider_failure()
          end

        %{} ->
          invalid_llm_provider_failure()
      end
    end
  end

  defp invalid_llm_provider_failure do
    %{
      status: :error,
      kind: :protocol_error,
      reason: :invalid_llm_provider_failure
    }
  end

  defp maybe_put_authenticated_replay(details, arguments, state) do
    case LLMReplayDiagnostic.failure_metadata(arguments) do
      %{replay_request_hash: request_hash} = replay ->
        if RunState.replay_miss?(state, request_hash),
          do: Map.merge(details, replay),
          else: details

      %{} ->
        details
    end
  end

  @doc false
  @spec maybe_put_llm_provider_failure(map(), RunState.t(), term(), term()) :: map()
  def maybe_put_llm_provider_failure(tools, state, event_sink, bundle) when is_map(tools) do
    if Library.shipped_component?(bundle, "agent.core") do
      Map.put(
        tools,
        "kernel-llm-provider-failure",
        instrument(
          state,
          event_sink,
          :workflow,
          "kernel-llm-provider-failure",
          llm_provider_failure(state)
        )
      )
    else
      tools
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

  @doc false
  @spec maybe_put_agent_loop_tools(map(), RunState.t(), term(), term()) :: map()
  def maybe_put_agent_loop_tools(tools, state, event_sink, bundle) when is_map(tools) do
    if Library.shipped_component?(bundle, "agent.core") do
      tools
      |> Map.put(
        "kernel-agent-config-failure",
        instrument(
          state,
          event_sink,
          :workflow,
          "kernel-agent-config-failure",
          agent_config_failure()
        )
      )
      |> Map.put(
        "kernel-agent-protocol-error",
        instrument(
          state,
          event_sink,
          :workflow,
          "kernel-agent-protocol-error",
          agent_protocol_error(state)
        )
      )
    else
      tools
    end
  end

  @doc false
  @spec agent_config_failure() :: (map() -> term())
  def agent_config_failure do
    fn arguments ->
      case agent_config_failure_details(arguments) do
        {:ok, details, message} ->
          %TrustedError{
            reason: :invalid_agent_config,
            message: message,
            details: details
          }

        :error ->
          invalid_agent_config_failure()
      end
    end
  end

  defp agent_config_failure_details(
         %{"option" => option, "min" => min, "max" => max, "value" => value} = arguments
       )
       when map_size(arguments) == 4 do
    details = %{option: option, min: min, max: max, value: value}

    case AgentConfigDiagnostic.integer_message(option, min, max, value) do
      {:ok, message} -> {:ok, details, message}
      :error -> :error
    end
  end

  defp agent_config_failure_details(
         %{"option" => option, "min" => min, "max" => max, "type" => type} = arguments
       )
       when map_size(arguments) == 4 do
    with {:ok, type} <- AgentConfigDiagnostic.type_tag(type),
         details <- %{option: option, min: min, max: max, type: type},
         {:ok, message} <- AgentConfigDiagnostic.type_message(option, min, max, type) do
      {:ok, details, message}
    else
      _invalid -> :error
    end
  end

  defp agent_config_failure_details(_arguments), do: :error

  defp invalid_agent_config_failure do
    %{
      status: :error,
      kind: :protocol_error,
      reason: :invalid_agent_config_failure
    }
  end

  @doc false
  @spec agent_protocol_error(RunState.t()) :: (map() -> term())
  def agent_protocol_error(state) do
    fn arguments ->
      case arguments do
        map when is_map(map) and map_size(map) == 0 ->
          case RunState.record_agent_protocol_error(state) do
            :ok -> true
            _failure -> invalid_agent_protocol_error()
          end

        _invalid ->
          invalid_agent_protocol_error()
      end
    end
  end

  defp invalid_agent_protocol_error do
    %{
      status: :error,
      kind: :protocol_error,
      reason: :invalid_agent_protocol_error
    }
  end

  # The branches below enumerate the closed kernel-eval envelope variants; the
  # repetition keeps every accepted map shape exact and rejects extra fields.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp dispatch_kernel_eval(
         state,
         target,
         arguments,
         limits,
         event_sink,
         inspection_sink,
         evaluation_opts
       ) do
    case arguments do
      %{"kind" => kind, "source" => source} = arguments
      when is_binary(source) and map_size(arguments) == 2 ->
        if keyword_name(kind) == "source" do
          evaluate_source(
            state,
            target,
            source,
            limits,
            event_sink,
            inspection_sink,
            evaluation_opts
          )
        else
          invalid_kernel_eval_request(state, event_sink)
        end

      %{
        "kind" => kind,
        "source" => source,
        "observation_chars" => observation_chars
      } = arguments
      when is_binary(source) and observation_chars in 1..65_536 and map_size(arguments) == 3 ->
        if keyword_name(kind) == "source" do
          evaluate_source(
            state,
            target,
            source,
            limits,
            event_sink,
            inspection_sink,
            evaluation_opts,
            observation_chars
          )
        else
          invalid_kernel_eval_request(state, event_sink)
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
            evaluation_opts
          )
        else
          invalid_kernel_eval_request(state, event_sink)
        end

      %{"kind" => kind, "program" => %Program{source: source}} = arguments
      when map_size(arguments) == 2 ->
        if keyword_name(kind) == "embedded" do
          evaluate_source(
            state,
            target,
            source,
            limits,
            event_sink,
            inspection_sink,
            evaluation_opts
          )
        else
          invalid_kernel_eval_request(state, event_sink)
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
            evaluation_opts
          )
        else
          invalid_kernel_eval_request(state, event_sink)
        end

      _rest ->
        invalid_kernel_eval_request(state, event_sink)
    end
  end

  @doc "Builds the workflow-only mission-aware source-check callback."
  def kernel_check_source(state, missions, limits, event_sink) when is_map(missions) do
    fn arguments ->
      with {:ok, mission_name, mission, rest} <- take_mission(arguments, missions),
           {:ok, source, opts} <- kernel_check_source_request(rest) do
        %{
          status: :ok,
          value: SourceCheck.check(state, mission_name, mission, source, limits, event_sink, opts)
        }
      else
        :error -> protocol_error(state, event_sink, :unknown_mission)
        _ -> invalid_kernel_check_source_request(state, event_sink)
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

  defp kernel_check_source_request(%{"source" => source} = arguments)
       when is_binary(source) and map_size(arguments) == 1,
       do: {:ok, source, []}

  defp kernel_check_source_request(%{"source" => source, "require" => require} = arguments)
       when is_binary(source) and map_size(arguments) == 2 do
    if keyword_name(require) == "terminal",
      do: {:ok, source, [required_shape: :terminal]},
      else: {:error, :invalid_request}
  end

  defp kernel_check_source_request(_arguments), do: {:error, :invalid_request}

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

      {"kernel-result-contract-failure" = name, callback} ->
        {name,
         %TrustedTool{
           function: callback,
           argument_projection: :raw,
           ledger_arguments: &result_contract_failure_ledger_arguments/1,
           prelude_namespaces: ["agent.core"],
           visibility: :private
         }}

      {"kernel-llm-provider-failure" = name, callback} ->
        {name,
         %TrustedTool{
           function: callback,
           prelude_namespaces: ["agent.core"],
           visibility: :private
         }}

      {"kernel-runtime-limit-failure" = name, callback} ->
        {name,
         %TrustedTool{
           function: callback,
           prelude_namespaces: ["agent.core"],
           visibility: :private
         }}

      {"kernel-agent-config-failure" = name, callback} ->
        {name,
         %TrustedTool{
           function: callback,
           prelude_namespaces: ["agent.core"],
           visibility: :private
         }}

      {"kernel-agent-protocol-error" = name, callback} ->
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
         evaluation_opts,
         observation_chars \\ nil
       ) do
    evaluation =
      state
      |> Evaluation.evaluate_source(
        mission_name,
        mission,
        source,
        limits.evaluation_timeout_ms,
        event_sink,
        inspection_sink,
        evaluation_opts
      )
      |> maybe_project_observation(observation_chars)

    %{
      status: :ok,
      value: evaluation
    }
  end

  defp maybe_project_observation(evaluation, max_chars) when is_integer(max_chars),
    do: EvaluationObservation.project(evaluation, max_chars)

  defp maybe_project_observation(evaluation, nil), do: evaluation

  defp evaluate_source_with(
         state,
         {mission_name, mission},
         source,
         params,
         limits,
         event_sink,
         inspection_sink,
         evaluation_opts
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
              Keyword.put(evaluation_opts, :params, params)
            )
        }

      {:error, _reason} ->
        invalid_kernel_eval_request(state, event_sink)
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
    %{}
    |> maybe_put_source_identity(arguments, limits.subordinate_source_bytes)
    |> maybe_put_source_requirement(arguments)
  end

  defp project_kernel_check_source_arguments(_arguments, _limits),
    do: %{"redacted" => true}

  defp maybe_put_source_requirement(projected, arguments) do
    if keyword_name(Map.get(arguments, "require")) == "terminal",
      do: Map.put(projected, "require", "terminal"),
      else: projected
  end

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
        invalid_result_contract(ValueContract.model_feedback(contract, json_value))
      end
    else
      {:error, _reason} ->
        invalid_json_result_contract(contract, value)
    end
  end

  defp invalid_json_result_contract(contract, value) do
    details =
      contract
      |> ValueContract.model_feedback(value)
      |> Map.put(:json_value, false)
      |> Map.put(:violations, [])

    invalid_result_contract(details)
  end

  defp invalid_result_contract(details) do
    %{status: :ok, value: %{enforced?: true, valid?: false, details: details}}
  end

  @doc false
  @spec result_contract_failure(ValueContract.t() | nil, binary() | nil) :: (map() -> term())
  def result_contract_failure(%ValueContract{} = contract, contract_source) do
    fn
      %{"value" => value, "agent_turns" => agent_turns} = arguments
      when map_size(arguments) == 2 and agent_turns in 1..128 ->
        result_contract_failure(contract, contract_source, value, agent_turns)

      _invalid ->
        invalid_result_contract_failure()
    end
  end

  def result_contract_failure(_contract, _contract_source),
    do: fn _arguments -> invalid_result_contract_failure() end

  defp result_contract_failure(contract, contract_source, value, agent_turns) do
    case Lisp.project_boundary_value(value, :kernel_json) do
      {:ok, projected} ->
        projected_result_contract_failure(
          contract,
          contract_source,
          value,
          projected,
          agent_turns
        )

      {:error, _projection_error} ->
        non_json_result_contract_failure(contract, contract_source, value, agent_turns)
    end
  end

  defp projected_result_contract_failure(
         contract,
         contract_source,
         original_value,
         projected,
         agent_turns
       ) do
    with {:ok, json_value} <- ValueContract.json_value(projected),
         false <- ValueContract.valid?(contract, json_value),
         {:ok, classification} <- ValueContractDiagnostic.classify(contract, json_value),
         {:ok, details} <- terminal_contract_details(classification, contract_source, agent_turns) do
      %TrustedError{
        reason: :result_contract_failed,
        message: "agent result contract correction exhausted",
        details: details
      }
    else
      {:error, reason} when reason in [:duplicate_key, :invalid_json] ->
        non_json_result_contract_failure(contract, contract_source, original_value, agent_turns)

      _invalid_or_satisfied ->
        invalid_result_contract_failure()
    end
  end

  defp non_json_result_contract_failure(contract, contract_source, value, agent_turns) do
    case ValueContractDiagnostic.classify(contract, value) do
      {:ok, classification} ->
        details =
          classification
          |> Map.take([:contract_authority])
          |> Map.put(:agent_turns, agent_turns)
          |> Map.put(:constraint, :json_value)
          |> Map.put(:violations, [])
          |> maybe_put_contract_source(contract_source)

        %TrustedError{
          reason: :result_contract_failed,
          message: "agent result contract correction exhausted",
          details: details
        }

      {:error, :invalid_contract_classification} ->
        invalid_result_contract_failure()
    end
  end

  defp terminal_contract_details(classification, contract_source, agent_turns) do
    case terminal_contract_violation(classification) do
      %{kind: constraint} = violation when is_atom(constraint) ->
        details =
          classification
          |> Map.take([:contract_authority])
          |> Map.put(:agent_turns, agent_turns)
          |> Map.put(:constraint, constraint)
          |> Map.put(:violations, [Map.take(violation, [:kind, :path, :missing_required])])
          |> maybe_put_contract_source(contract_source)

        {:ok, details}

      _unclassified ->
        {:error, :invalid_contract_classification}
    end
  end

  defp terminal_contract_violation(%{violations: violations}) when is_list(violations) do
    violations
    |> Enum.filter(fn
      %{kind: kind, path: %{segments: segments}} when is_atom(kind) and is_list(segments) -> true
      _invalid -> false
    end)
    |> Enum.sort_by(fn %{kind: kind, path: %{segments: segments}} ->
      {segments == [], segments, Atom.to_string(kind)}
    end)
    |> List.first()
  end

  defp terminal_contract_violation(_classification), do: nil

  defp maybe_put_contract_source(details, source) when is_binary(source),
    do: Map.put(details, :contract_source, source)

  defp maybe_put_contract_source(details, _source), do: details

  defp invalid_result_contract_failure do
    %TrustedError{
      reason: :invalid_result_contract_failure,
      message: "invalid result contract failure transition",
      details: %{}
    }
  end

  @doc false
  def result_contract_failure_ledger_arguments(_arguments), do: %{"redacted" => true}

  @doc false
  @spec maybe_put_result_contract_failure(
          map(),
          RunState.t(),
          term(),
          ValueContract.t() | nil,
          binary() | nil,
          term()
        ) :: map()
  def maybe_put_result_contract_failure(
        tools,
        state,
        event_sink,
        contract,
        contract_source,
        bundle
      )
      when is_map(tools) do
    if Library.shipped_component?(bundle, "agent.core") do
      Map.put(
        tools,
        "kernel-result-contract-failure",
        instrument(
          state,
          event_sink,
          :workflow,
          "kernel-result-contract-failure",
          result_contract_failure(contract, contract_source)
        )
      )
    else
      tools
    end
  end

  @doc """
  Wraps an internal runtime callback with canonical capability events.

  An error `capability-stopped` event carries the closed envelope `kind` and
  `reason` when those atoms belong to the Kernel vocabulary. An unrecognized
  atom is retained only as a one-way fingerprint. Arguments, details, and
  messages stay off the event.
  """
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

          stopped =
            attributes
            |> Map.merge(%{
              capability_id: capability_id,
              environment: environment,
              name: name,
              status: result_status(result),
              duration_ms: Events.duration_ms(started_ms)
            })
            |> Events.put_rejection_class(result)

          _ = Events.emit(state, event_sink, "capability-stopped", stopped)

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

  defp route_callback(:usage, state, _environment, event_sink, kind, lease),
    do: fn arguments -> usage(state, arguments, {kind, lease, event_sink}) end

  defp route_callback(:remaining, state, _environment, event_sink, kind, lease),
    do: fn arguments -> remaining(state, arguments, {kind, lease, event_sink}) end

  defp route_callback(:capability_list, state, environment, event_sink, kind, lease),
    do: fn arguments ->
      capability_list(state, environment, arguments, {kind, lease, event_sink})
    end

  defp route_callback(:capability_description, state, environment, event_sink, kind, lease),
    do: fn arguments ->
      capability_description(state, environment, arguments, {kind, lease, event_sink})
    end

  # Malformed-call accounting for a mission route authenticates the lease in
  # the same owner operation that records the error.
  defp scoped_protocol_error(state, reason, {kind, lease, event_sink}) do
    case RunState.protocol_error(state, kind, lease) do
      :ok ->
        %{status: :error, kind: :protocol_error, reason: reason}

      {:error, :stale_evaluation} ->
        %{status: :error, kind: :capability_denied, reason: :stale_evaluation, retryable?: false}

      {:error, :protocol_error_limit} ->
        protocol_error_limit_envelope(state, event_sink)
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

  defp annotate(state, event_sink, _arguments),
    do: protocol_error(state, event_sink, :invalid_workflow_annotation)

  defp protocol_error(state, event_sink, reason) do
    case RunState.protocol_error(state) do
      :ok ->
        %{status: :error, kind: :protocol_error, reason: reason}

      {:error, :protocol_error_limit} ->
        protocol_error_limit_envelope(state, event_sink)
    end
  end

  defp invalid_kernel_eval_request(state, event_sink) do
    case RunState.protocol_error(state) do
      :ok ->
        %{
          status: :error,
          kind: :protocol_error,
          reason: :invalid_kernel_eval_request,
          retryable?: false
        }

      {:error, :protocol_error_limit} ->
        protocol_error_limit_envelope(state, event_sink, %{retryable?: false})
    end
  end

  defp invalid_kernel_check_source_request(state, event_sink) do
    case RunState.protocol_error(state) do
      :ok ->
        %{
          status: :error,
          kind: :protocol_error,
          reason: :invalid_kernel_check_source_request,
          retryable?: false
        }

      {:error, :protocol_error_limit} ->
        protocol_error_limit_envelope(state, event_sink, %{retryable?: false})
    end
  end

  defp protocol_error_limit_envelope(state, event_sink, extra \\ %{}) do
    details = RunState.protocol_errors_details(state)

    _ =
      Events.emit(
        state,
        event_sink,
        "limit-exceeded",
        Map.merge(%{reason: :protocol_errors}, details)
      )

    Map.merge(
      %{
        status: :error,
        kind: :limit_exceeded,
        reason: :protocol_errors,
        details: details
      },
      extra
    )
  end

  defp keyword_name(%LispKeyword{name: name}), do: name
  defp keyword_name(name) when is_atom(name), do: Atom.to_string(name)
  defp keyword_name(name) when is_binary(name), do: name
  defp keyword_name(_value), do: nil

  defp result_status(%{status: status}), do: status
  defp result_status(_result), do: :ok
end
