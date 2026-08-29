defmodule PtcRunner.Kernel.EventBudget do
  @moduledoc false

  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Lisp.RetainedSize

  @drop_count_limit 4_294_967_295
  @max_drop_type_prefix "e" <> String.duplicate("a", 124)
  @maximum_terminal_reason String.duplicate("r", 1_020)
  @maximum_repl_errors 4_294_967_295
  # Exact retained-size upper bound for the complete maximum bounded
  # `run-stopped` payload on the supported 64-bit runtime: saturated drop map,
  # bounded terminal reason, and every fixed usage field at catalog maxima with
  # an empty capability and mission inventory, including `llm_spend` and
  # `agent_protocol_errors`. Keep this explicit because sizing a constructed
  # literal can undercount the ref-counted binaries retained by a real sink.
  @minimum_normal_payload_bytes 8_211
  @maximum_dropped_bytes 3_449

  @doc false
  def maximum_dropped do
    1..16
    |> Map.new(fn index ->
      suffix = String.pad_leading(Integer.to_string(index), 3, "0")
      {"#{@max_drop_type_prefix}#{suffix}", @drop_count_limit}
    end)
    |> Map.put("$overflow", @drop_count_limit)
  end

  @doc false
  def maximum_dropped_with_headroom do
    dropped = maximum_dropped()
    bytes = RetainedSize.bytes(dropped)
    {dropped, max(@maximum_dropped_bytes - bytes, 0)}
  end

  @doc false
  def maximum_terminal_reason, do: :binary.copy(@maximum_terminal_reason)

  @doc false
  def minimum_normal_payload_bytes, do: @minimum_normal_payload_bytes

  @doc false
  def normal_terminal_payload_capacity?(limit) when is_integer(limit) and limit > 0,
    do: limit >= @minimum_normal_payload_bytes

  def normal_terminal_payload_capacity?(_limit), do: false

  @doc false
  @spec maximum_event_bytes(binary(), pos_integer()) :: pos_integer()
  def maximum_event_bytes(type, payload_bytes)
      when is_binary(type) and is_integer(payload_bytes) and payload_bytes > 0,
      do: terminal_envelope_bytes(type) + payload_bytes

  @doc false
  def terminal_envelope_bytes(type) when is_binary(type) do
    envelope = %{
      schema_version: 2,
      run_id: String.duplicate("r", 256),
      trace_id: String.duplicate("t", 256),
      sequence: @drop_count_limit,
      timestamp: ~U[9999-12-31 23:59:59.999999Z],
      type: type,
      data: nil
    }

    RetainedSize.bytes(envelope)
  end

  @doc false
  @spec maximum_terminal_usage(map(), map(), [binary()], Limits.t()) :: map()
  def maximum_terminal_usage(
        workflow_capabilities,
        mission_capabilities,
        mission_names,
        %Limits{} = limits
      )
      when is_map(workflow_capabilities) and is_map(mission_capabilities) and
             is_list(mission_names) do
    %{
      closed?: true,
      remaining_ms: limits.run_duration_ms,
      capability_calls: %{
        workflow:
          maximum_call_map(
            workflow_capabilities,
            limits.workflow_capability_calls,
            limits.workflow_capability_calls_per_name
          ),
        mission:
          maximum_call_map(
            mission_capabilities,
            limits.mission_capability_calls,
            limits.mission_capability_calls_per_name
          )
      },
      subordinate_evaluations: limits.subordinate_evaluations,
      evaluations_by_mission: Map.new(mission_names, &{&1, limits.subordinate_evaluations}),
      subordinate_source_checks: limits.subordinate_source_checks,
      protocol_errors: limits.protocol_errors + 1,
      evaluation_memory_bytes: limits.evaluation_memory_bytes,
      evaluation_history_bytes: limits.evaluation_history_bytes,
      evaluation_continuation_bytes:
        limits.evaluation_memory_bytes + limits.evaluation_history_bytes,
      evaluation_busy?: true,
      evaluation_missions: Enum.sort(mission_names),
      errors: @maximum_repl_errors,
      agent_protocol_errors: @drop_count_limit,
      capability_refusals: maximum_capability_refusals(),
      llm_budget: maximum_llm_budget(limits),
      llm_spend: maximum_llm_spend()
    }
  end

  @doc false
  @spec catalog_floor_usage() :: map()
  def catalog_floor_usage do
    maximum_terminal_usage(%{}, %{}, [], catalog_maximum_limits())
  end

  @doc false
  @spec required_terminal_payload_bytes(atom(), map()) :: pos_integer() | :error
  def required_terminal_payload_bytes(policy, usage)
      when policy in [:normal, :private] and is_map(usage) do
    {dropped, drop_map_headroom} =
      if policy == :normal,
        do: maximum_dropped_with_headroom(),
        else: {%{}, 0}

    usage = Map.put(usage, :events_dropped, dropped)

    payloads = [
      %{outcome: :error, reason: maximum_terminal_reason(), usage: usage},
      %{
        outcome: :ok,
        reason: nil,
        result_hash: "sha256:" <> String.duplicate("f", 64),
        usage: usage
      }
    ]

    case Enum.reduce_while(payloads, 0, fn payload, acc ->
           case normalized_payload_bytes(payload) do
             bytes when is_integer(bytes) -> {:cont, max(acc, bytes)}
             :error -> {:halt, :error}
           end
         end) do
      :error -> :error
      max_bytes -> max_bytes + drop_map_headroom
    end
  end

  def required_terminal_payload_bytes(_policy, _usage), do: :error

  defp catalog_maximum_limits do
    overrides = Map.new(LimitCatalog.rows(), &{&1.field, &1.maximum})
    {:ok, limits} = Limits.installed(overrides)
    limits
  end

  defp normalized_payload_bytes(payload) do
    with {:ok, normalized} <- JSONValue.normalize(payload),
         bytes when is_integer(bytes) <- RetainedSize.bytes(normalized) do
      bytes
    else
      _invalid -> :error
    end
  end

  defp maximum_llm_budget(limits) do
    maximum = 9_007_199_254_740_991

    %{
      "total_tokens" =>
        if(is_nil(limits.llm_total_tokens),
          do: nil,
          else: %{
            "state" => "incomplete",
            "limit" => limits.llm_total_tokens,
            "reserved" => 0,
            "charged" => maximum,
            "remaining" => 0,
            "refused" => maximum
          }
        ),
      "cost" =>
        if(is_nil(limits.llm_cost_microusd),
          do: nil,
          else: %{
            "state" => "incomplete",
            "currency" => "USD",
            "limit_microusd" => limits.llm_cost_microusd,
            "reserved_microusd" => 0,
            "charged_microusd" => maximum,
            "remaining_microusd" => 0,
            "refused" => maximum
          }
        )
    }
  end

  defp maximum_llm_spend do
    maximum = 9_007_199_254_740_991

    %{
      "state" => "available",
      "input" => maximum,
      "output" => maximum,
      "total_cost" => %{"currency" => "USD", "microunits" => maximum}
    }
  end

  # Closed class keys cannot be grown from caller input, but a trusted resolver
  # may still mint unrecognized atoms. Distinct keys are capped at the same
  # limit RunState enforces, plus `$overflow`, and reserved at fingerprint
  # length so a named class cannot enlarge run-stopped past event_payload_bytes.
  defp maximum_capability_refusals do
    fingerprint = "sha256:" <> String.duplicate("f", 64)
    count = @drop_count_limit
    limit = SafeMetadata.capability_refusal_map_limit()

    1..limit
    |> Map.new(fn index ->
      {"workflow/#{fingerprint}/#{fingerprint}-#{index}", count}
    end)
    |> Map.put("$overflow", count)
  end

  defp maximum_call_map(capabilities, total_limit, per_name_limit) do
    maximum_count = min(total_limit, per_name_limit)

    capabilities
    |> Map.keys()
    |> Enum.sort_by(&{-retained_name_bytes(&1), &1})
    |> Enum.take(total_limit)
    |> Map.new(&{&1, maximum_count})
  end

  defp retained_name_bytes(name) do
    case RetainedSize.bytes(name) do
      bytes when is_integer(bytes) -> bytes
      :oversized -> 9_223_372_036_854_775_807
    end
  end
end
